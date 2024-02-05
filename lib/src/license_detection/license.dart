// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of 'license_detector.dart';

/// Regular expression to match the common pattern of `Copyright (c) yyyy[-yyyy] <name>.`
final _copyrightRegExp =
    RegExp(r'^copyright\s+(?:\(c\)|©)\s+\d{4}.{0,100}$', caseSensitive: false);

@sealed
class License {
  /// SPDX identifier of the license, is empty in case of unknown license.
  final String identifier;

  /// Original text from the license file.
  final String content;

  /// Normalized [Token]s created from the original text.
  final List<Token> tokens;

  /// Map from [Token.value] to their number of occurrences in this license.
  final Map<String, int> tokenFrequency;

  License._(this.content, this.tokens, this.tokenFrequency, this.identifier);

  factory License.parse({required String identifier, required String content}) {
    // Remove some known patterns from the licenses that are not needed during matching.
    final lines = content.split('\n');

    // Remove `<IDENTIFIER> License:` as the first line, found in ISC license
    if (lines.isNotEmpty &&
        lines.first.toLowerCase() == '${identifier.toLowerCase()} license:') {
      lines.removeAt(0);
    }

    // Remove `Copyright (c) yyyy[-yyyy] <name>.` and similar patterns.
    lines.removeWhere((line) => _copyrightRegExp.matchAsPrefix(line) != null);

    final strippedContent = lines.join('\n');
    final tokens = tokenize(strippedContent);
    final table = generateFrequencyTable(tokens);
    return License._(strippedContent, tokens, table, identifier);
  }
}

String normalizedContent(Iterable<Token> tokens) {
  return tokens.map((token) => token.value).join(' ');
}

/// Representation of a n-gram consisting of `n` tokens.
///
/// The number of tokens `n` in the n-grams is determined by the confidence threshold for the match.
/// See: [computeGranularity].
@sealed
class NGram {
  /// Text for which the hash value was generated.
  @visibleForTesting
  final String text;

  /// [CRC-32][1] checksum value generated for text.
  ///
  /// [1]: https://en.wikipedia.org/wiki/Cyclic_redundancy_check
  final int checksum;

  /// Index of the first token in the checksum.
  final int start;

  /// Index of the last token in the checksum.
  final int end;

  NGram(this.text, this.checksum, this.start, this.end);
}

/// A [License] instance with generated [nGrams].
@visibleForTesting
@sealed
class LicenseWithNGrams extends License {
  /// List of [NGram]s generated by taking [granularity] tokens at a time.
  final List<NGram> nGrams;

  /// Maps from [NGram.checksum] to a list of [NGram] having equal `CRC-32` checksum.
  final Map<int, List<NGram>> checksumMap;

  /// Number of tokens combined at a time to create a [NGram].
  final int granularity;

  LicenseWithNGrams._(
    this.nGrams,
    this.checksumMap,
    this.granularity,
    String identifier,
    String content,
    List<Token> tokens,
    Map<String, int> table,
  ) : super._(
          content,
          tokens,
          table,
          identifier,
        );

  factory LicenseWithNGrams.parse(License license, int n) {
    final nGrams = generateChecksums(license.tokens, n);
    final table = generateChecksumMap(nGrams);
    return LicenseWithNGrams._(
      nGrams,
      table,
      license.tokens.length < n ? license.tokens.length : n,
      license.identifier,
      license.content,
      license.tokens,
      license.tokenFrequency,
    );
  }
}

/// Contains details regarding the results of corpus license match with unknown text.
@sealed
class LicenseMatch {
  /// Sequence of tokens from input text that were considered a match for the detected [License].
  @visibleForTesting
  final List<Token> tokens;

  /// [Diff]s calculated between target tokens and [license] tokens.
  @visibleForTesting
  final List<Diff> diffs;

  /// Range of [diffs] which represents the diffs between known license and unknown license.
  ///
  /// Diffs lying outside of [diffRange] represent additional text in unknown license
  /// comes before or after the detected [license](source) text.
  @visibleForTesting
  final Range diffRange;

  /// Detected license the input have been found to match with given [confidence].
  @visibleForTesting
  final LicenseWithNGrams license;

  /// Confidence score of the detected license.
  final double confidence;

  String get identifier => license.identifier;

  /// Offset in the input license text considered to be possible starting point
  /// of known license subtring.
  int get start => tokens.first.span.start.offset;

  /// Offset in the input license text considered to be possible starting point
  /// of known license subtring.
  int get end => tokens.last.span.end.offset;

  /// Count of the tokens claimed in this match.
  ///
  /// It is intialized to the number of tokens claimed by this match.
  /// Incase of match with the same spdx-identifier we create a new
  /// instance with tokenClaimed assigned to the maximum of both
  /// the identical matches.
  ///
  /// For example in license such as `AGPL-3.0` which contains optional
  /// text after the `END OF TERMS AND CONDITION` statement there are two
  /// instances of known licenses with the same identifier. The license match
  /// will have more tokens claimed if the unknown license text contains the
  /// optional text and hence we update tokens claimed always to the
  /// maximum of the same identifier.
  @visibleForTesting
  final int tokensClaimed;

  /// Range of tokens in the unknown text claimed by this match.
  ///
  /// Range is initilalized from start index of first
  /// token claimed in the match
  @visibleForTesting
  final Range tokenRange;

  @visibleForTesting
  LicenseMatch(
    this.tokens,
    this.confidence,
    this.license,
    this.diffs,
    this.diffRange,
  )   : tokensClaimed = tokens.length,
        tokenRange = Range(tokens.first.index, tokens.last.index);

  @visibleForTesting
  LicenseMatch.createInstance(
    this.tokens,
    this.confidence,
    this.tokensClaimed,
    this.diffRange,
    this.diffs,
    this.license,
    this.tokenRange,
  );

  LicenseMatch updateTokenIndex(int startIndex, int endIndex) {
    return LicenseMatch.createInstance(
      tokens,
      confidence,
      endIndex - startIndex,
      diffRange,
      diffs,
      license,
      Range(startIndex, endIndex),
    );
  }
}

/// Generates a frequency table for the given list of [tokens].
///
/// [Token.value] is mapped to the number of occurrences in the license text.
@visibleForTesting
Map<String, int> generateFrequencyTable(List<Token> tokens) {
  final table = <String, int>{};

  for (var token in tokens) {
    table[token.value] = (table[token.value] ?? 0) + 1;
  }

  return table;
}

/// Load a list of [License] from the license files in [directories].
///
/// The license files in [directories] are expected to be plain `.txt` with
/// proper `utf-8` encoding. Name of the license file is expected
/// to be in the form of [`<spdx-identifier>.txt`][1].
/// The [directories] are not searched recursively.
///
/// Throws if any of the [directories] contains a file not meeting the above criteria's.
///
/// [1]: https://spdx.dev/ids/
List<License> loadLicensesFromDirectories(Iterable<String> directories) {
  final licenses = <License>[];

  for (var dir in directories) {
    Directory(dir).listSync(recursive: false).forEach((file) {
      if (file.path.endsWith('.txt')) {
        final license = licensesFromFile(file.path);
        licenses.addAll(license);
      } else {
        throw FormatException(
          'Invalid file type:\nExpected: "spdx-identifier" Actual: ${file.uri.pathSegments.last}',
        );
      }
    });
  }
  licenses.sort((a, b) => a.identifier.compareTo(b.identifier));
  return List.unmodifiable(licenses);
}

/// Returns a list of [License] from the given license file.
///
/// If license text contains the phrase `END OF TERMS AND CONDITIONS`
/// which indicates the presence of optional text, two instances
/// of [License] are returned.
///
/// Throws if file is not properly encoded or name of the file is an
/// invalid [SPDX identifier][1].
///
/// [1]: https://github.com/spdx/license-list-XML/blob/master/DOCS/license-fields.md#explanation-of-spdx-license-list-fields
@visibleForTesting
List<License> licensesFromFile(String path) {
  final licenses = <License>[];
  final file = File(path);

  final content = file.readAsStringSync();
  final identifier = file.uri.pathSegments.last.split('.txt').first;

  if (_invalidIdentifier.hasMatch(identifier)) {
    throw ArgumentError(
      'Invalid file name: expected: "path/to/file/<spdx-identifier>.txt" actual: $path',
    );
  }

  licenses.add(License.parse(identifier: identifier, content: content));

  // If a license contains a optional part create an additional license
  // instance with the optional part of text removed to have
  // better chances of matching.
  if (content.contains(_endOfTerms)) {
    final modifiedContent = content.split(_endOfTerms).first + _endOfTerms;
    licenses
        .add(License.parse(identifier: identifier, content: modifiedContent));
  }
  return licenses;
}

/// Regex to match the all the text starting from `END OF TERMS AND CONDTIONS`.
const _endOfTerms = 'END OF TERMS AND CONDITIONS';

/// Generates crc-32 checksum for the given list of tokens
/// by taking [granularity] token values at a time.
@visibleForTesting
List<NGram> generateChecksums(List<Token> tokens, int granularity) {
  if (tokens.length < granularity) {
    final text = tokens.join(' ');
    return [NGram(text, crc32(utf8.encode(text)), 0, tokens.length - 1)];
  }

  var nGrams = <NGram>[];

  for (var i = 0; i + granularity <= tokens.length; i++) {
    var text = '';
    tokens.skip(i).take(granularity).forEach((token) {
      text = '$text${token.value} ';
    });

    final crcValue = crc32(utf8.encode(text));

    nGrams.add(NGram(text, crcValue, i, i + granularity));
  }

  return nGrams;
}

/// Generates a frequency table for the given list of [nGrams].
///
/// [NGram.checksum] is mapped to a list of NGrams having the same
/// checksum value.
@visibleForTesting
Map<int, List<NGram>> generateChecksumMap(List<NGram> nGrams) {
  final table = <int, List<NGram>>{};
  for (var gram in nGrams) {
    table.putIfAbsent(gram.checksum, () => []).add(gram);
  }

  return table;
}

/// Identifier not following the norms of  [SPDX short identifier][1]
/// is a invalid identifier.
///
/// [1]: https://github.com/spdx/license-list-XML/blob/master/DOCS/license-fields.md#explanation-of-spdx-license-list-fields
final _invalidIdentifier = RegExp(r'[^a-zA-Z\d\.\-\_+]');
