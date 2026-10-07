import 'package:flutter/foundation.dart';

/// What the remote actually lets us rely on.
///
/// v3.0 §6.3 defines three CI profiles — Nextcloud (everything), Synology
/// (no CTag), nginx-dav (no If-Match) — because the properties that decide
/// whether a sync is *safe* are exactly the ones these servers disagree
/// about. This object is persisted as JSON in `sync_roots.capabilities`.
@immutable
class DavCapabilities {
  const DavCapabilities({
    this.supportsCtag = false,
    this.etagIsWeak = false,
    this.supportsIfMatch = false,
    this.supportsIfNoneMatch = false,
    this.supportsPropfindDepth1 = true,
    this.supportsPropfindInfinity = false,
    this.davClasses = const <String>{},
    this.server,
    this.probedAt,
  });

  /// Server returns `getctag` on collections, so an unchanged collection can
  /// be skipped entirely. Without it every round is a full Depth:1 PROPFIND.
  final bool supportsCtag;

  /// ETags carry the `W/` prefix. RFC 7232 requires *strong* comparison for
  /// If-Match, so against a weak-etag server an If-Match can never succeed.
  /// When this is true the sync engine must fall back to comparing content
  /// hashes and accept a narrow lost-update window.
  final bool etagIsWeak;

  /// Server evaluates If-Match on PUT/DELETE. This is the difference between
  /// atomic convergence and a silent overwrite (ADR-8).
  final bool supportsIfMatch;

  /// Server evaluates If-None-Match, giving us atomic create-if-absent.
  final bool supportsIfNoneMatch;

  final bool supportsPropfindDepth1;

  /// Almost nobody allows this. Never depend on it; the client refuses to
  /// ask for infinity regardless of what the server claims.
  final bool supportsPropfindInfinity;

  /// Tokens from the `DAV:` response header, e.g. `{1, 2, access-control}`.
  final Set<String> davClasses;

  final String? server;

  /// When this profile was last confirmed against the server. A profile older
  /// than a few weeks is worth re-probing.
  final DateTime? probedAt;

  /// Conservative default used before anything is known about the server.
  /// Assumes nothing works: full listing every round, hash comparison for
  /// change detection, no atomic write protection.
  static const DavCapabilities unknown = DavCapabilities();

  DavCapabilities copyWith({
    bool? supportsCtag,
    bool? etagIsWeak,
    bool? supportsIfMatch,
    bool? supportsIfNoneMatch,
    bool? supportsPropfindDepth1,
    bool? supportsPropfindInfinity,
    Set<String>? davClasses,
    String? server,
    DateTime? probedAt,
  }) {
    return DavCapabilities(
      supportsCtag: supportsCtag ?? this.supportsCtag,
      etagIsWeak: etagIsWeak ?? this.etagIsWeak,
      supportsIfMatch: supportsIfMatch ?? this.supportsIfMatch,
      supportsIfNoneMatch: supportsIfNoneMatch ?? this.supportsIfNoneMatch,
      supportsPropfindDepth1: supportsPropfindDepth1 ?? this.supportsPropfindDepth1,
      supportsPropfindInfinity:
          supportsPropfindInfinity ?? this.supportsPropfindInfinity,
      davClasses: davClasses ?? this.davClasses,
      server: server ?? this.server,
      probedAt: probedAt ?? this.probedAt,
    );
  }

  /// Merges evidence gathered during live traffic into the declared profile.
  ///
  /// `supportsIfMatch` is deliberately *not* inferred from a 412: a 412
  /// proves the server evaluated the precondition, but so does a silent 204
  /// from a server that compares by luck. Proving support requires a write,
  /// and JotIt does not probe by writing — it learns from writes it needed
  /// anyway, and the CI matrix supplies the rest.
  DavCapabilities observed({
    bool? sawCtag,
    bool? sawWeakEtag,
    bool? acceptedPrecondition,
    bool? refusedPrecondition,
    String? sawServer,
    DateTime? at,
  }) {
    return copyWith(
      supportsCtag: sawCtag == false ? false : supportsCtag,
      etagIsWeak: sawWeakEtag == true ? true : etagIsWeak,
      supportsIfMatch: acceptedPrecondition == false
          ? false
          : (refusedPrecondition == true ? true : supportsIfMatch),
      server: sawServer ?? server,
      probedAt: at ?? probedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'supports_ctag': supportsCtag,
        'etag_is_weak': etagIsWeak,
        'supports_if_match': supportsIfMatch,
        'supports_if_none_match': supportsIfNoneMatch,
        'supports_propfind_depth1': supportsPropfindDepth1,
        'dav_classes': davClasses.toList()..sort(),
        'server': server,
        'probed_at': probedAt?.toIso8601String(),
      };

  static DavCapabilities fromJson(Map<String, Object?> json) {
    final classes = json['dav_classes'];
    return DavCapabilities(
      supportsCtag: json['supports_ctag'] == true,
      etagIsWeak: json['etag_is_weak'] == true,
      supportsIfMatch: json['supports_if_match'] == true,
      supportsIfNoneMatch: json['supports_if_none_match'] == true,
      supportsPropfindDepth1: json['supports_propfind_depth1'] != false,
      davClasses: classes is List
          ? {for (final c in classes) '$c'}
          : const <String>{},
      server: json['server'] as String?,
      probedAt: DateTime.tryParse('${json['probed_at']}'),
    );
  }

  @override
  String toString() =>
      'DavCapabilities(ctag: $supportsCtag, weakEtag: $etagIsWeak, '
      'ifMatch: $supportsIfMatch, ifNoneMatch: $supportsIfNoneMatch, '
      'server: $server)';
}