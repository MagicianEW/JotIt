import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Content hashing for sync identity and change detection.
///
/// Every hash in JotIt is over **raw file bytes**, never over a parsed or
/// re-serialized form. Re-serializing would make the hash depend on our own
/// line-ending or whitespace normalisation, which would show up as phantom
/// changes on every sync (and would break the three-way merge bases in
/// [DecisionMatrix]).
abstract final class ContentHash {
  /// SHA-256 of raw bytes, lowercase hex.
  static String ofBytes(List<int> bytes) =>
      sha256.convert(bytes).toString().toLowerCase();

  /// SHA-256 of a string's UTF-8 encoding.
  ///
  /// Only for hashing *in-memory payloads we generate ourselves* (queue
  /// entries, JSON). Never use this to hash a file that was loaded into a
  /// Dart string — read the bytes instead, or the CRLF/LF difference between
  /// Windows and POSIX will produce a false "changed" verdict.
  static String ofString(String value) => ofBytes(utf8.encode(value));

  /// Cheap 64-bit fingerprint used only for progress reporting and dedupe
  /// hints. Never load-bearing for correctness.
  static int quickFingerprint(List<int> bytes) =>
      sha1.convert(bytes).bytes.sublist(0, 8).fold<int>(
            0,
            (acc, b) => (acc * 31 + b) & 0x7FFFFFFFFFFFFFFF,
          );
}