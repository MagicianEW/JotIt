import 'package:jotit/core/vault_paths.dart';

/// Conflict quarantine naming (v3.0 §7.2).
///
/// The one hard rule: nothing produced here is ever synchronised. It lives in
/// `<vault>/_conflicts/`, a **sibling** of `notes/`, and the scanner walks only
/// `notes/`. v2.0 declared conflict files non-syncing but stored them inside
/// the notes tree, so each device re-uploaded the other's conflict copies and
/// the directory multiplied without bound.
abstract final class ConflictNaming {
  /// `20260108-142305-1-daily-2024-01-01`
  ///
  /// The timestamp and sequence make collisions effectively impossible: two
  /// conflicts detected in the same second on the same path would otherwise
  /// overwrite each other (v2.0 P2-14).
  static String directoryName({
    required DateTime when,
    required String originalPath,
    required int sequence,
  }) {
    final stamp = '${when.year.toString().padLeft(4, '0')}'
        '${_two(when.month)}'
        '${_two(when.day)}'
        '-'
        '${_two(when.hour)}'
        '${_two(when.minute)}'
        '${_two(when.second)}';
    final base = VaultPaths.sanitizeSegment(_stripExtension(originalPath));
    return '$stamp-$sequence-$base';
  }

  /// Find the lowest sequence number whose directory does not yet exist.
  ///
  /// The existence check is injected so this stays a pure, testable function;
  /// the caller supplies the real filesystem probe.
  static int nextSequence({
    required DateTime when,
    required String originalPath,
    required bool Function(String candidate) exists,
    int startAt = 1,
    int maxTries = 1000,
  }) {
    for (var i = startAt; i < startAt + maxTries; i++) {
      if (!exists(directoryName(
        when: when,
        originalPath: originalPath,
        sequence: i,
      ))) {
        return i;
      }
    }
    throw StateError(
      'Could not find a free conflict slot for $originalPath after $maxTries tries',
    );
  }

  static String _stripExtension(String path) {
    final base = path.split('/').last;
    final dot = base.lastIndexOf('.');
    return dot <= 0 ? base : base.substring(0, dot);
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}