import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'dav_capabilities.dart';
import 'dav_exception.dart';
import 'dav_multistatus.dart';

/// Precondition attached to a mutating request.
///
/// Modelled as a sealed hierarchy rather than two nullable strings because
/// the difference is load-bearing: sending `If-Match` when the resource does
/// not exist yet makes RFC 7232 answer 412, which would make *every first
/// upload of every new note* fail forever. Creation and update therefore
/// need genuinely different shapes, not a null check.
sealed class DavCondition {
  const DavCondition();
}

/// No precondition at all — last write wins. Only correct for a resource we
/// have never seen, or against a server that ignores preconditions anyway.
class DavUnconditional extends DavCondition {
  const DavUnconditional();
}

/// `If-Match: <etag>` — write only if the resource still has this exact tag.
/// ADR-8 depends on this being atomic server-side.
class DavIfMatch extends DavCondition {
  const DavIfMatch(this.etag);
  final String etag;
}

/// `If-None-Match: *` — create only if the path does not exist. Server-side
/// atomic, so two devices racing to create the same path cannot both win.
class DavIfAbsent extends DavCondition {
  const DavIfAbsent();
}

/// Outcome of a successful PUT.
@immutable
class DavPutResult {
  const DavPutResult({required this.statusCode, required this.etag});
  final int statusCode;
  final String? etag;
  @override
  String toString() => 'DavPutResult($statusCode, etag: $etag)';
}

/// A WebDAV client scoped to one collection.
///
/// Every method takes a path relative to [baseUri] — `''` for the root
/// collection, `notes/a.md` for a file — and handles percent-encoding per
/// segment. Nothing above this layer ever sees a URL.
class DavClient {
  DavClient({
    required Uri baseUri,
    this.username,
    required this.password,
    this.capabilities = DavCapabilities.unknown,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : // A base without a trailing slash makes `Uri.resolve` drop the last
        // path segment, which silently writes every note one level too high.
        baseUri = baseUri.path.endsWith('/') ? baseUri : Uri.parse('${baseUri.toString()}/'),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  final Uri baseUri;
  final String? username;
  final String password;
  DavCapabilities capabilities;
  final Duration timeout;
  final http.Client _http;
  final bool _ownsHttpClient;

  static const String _userAgent = 'JotIt/3.0 (sync)';

  /// The XML the client asks for on every PROPFIND.
  ///
  /// `getctag` is requested even from servers that will not answer it: the
  /// 404 propstat that comes back is exactly the evidence that proves
  /// `supports_ctag` is false, which the client needs in order to stop
  /// asking.
  static const String propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:"><D:prop>'
      '<D:resourcetype/>'
      '<D:getetag/>'
      '<D:getctag/>'
      '<D:getcontentlength/>'
      '<D:getlastmodified/>'
      '<D:getcontenttype/>'
      '<D:displayname/>'
      '</D:prop></D:propfind>';

  /// URL for a *non-collection* resource. No trailing slash.
  ///
  /// The trailing slash is not cosmetic: `http://h/dav/a.md/` addresses a
  /// collection named `a.md`, not the file. Most servers tolerate the
  /// difference on GET and PUT, which is exactly why the mistake survives
  /// casual testing and then produces hrefs with a trailing slash that no
  /// longer match anything the client recorded.
  Uri urlFor(String path) {
    final joined = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return baseUri.resolve(joined);
  }

  /// URL for a collection. Always ends with a slash so relative resolution
  /// and the server's own path normalisation behave predictably.
  Uri collectionUrlFor(String path) {
    final joined = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return baseUri.resolve(joined.isEmpty ? '' : '$joined/');
  }

  /// No Authorization header at all when [username] is null — a WebDAV share
  /// can be anonymous, and sending `Basic null:password` is not the same
  /// thing as sending nothing.
  Map<String, String> get _auth => username == null
      ? <String, String>{}
      : <String, String>{
          // RFC 7617. Encoded by hand because a colon inside the password must
          // not be read as the username/password separator.
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:$password'))}',
        };

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
    Duration? timeoutOverride,
    Set<int> statusCodesAsResults = const <int>{},
  }) async {
    final request = http.Request(method, uri)
      ..headers.addAll(_auth)
      ..headers['User-Agent'] = _userAgent;
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.bodyBytes = body;

    final http.Response response;
    try {
      final streamed = await _http
          .send(request)
          .timeout(timeoutOverride ?? timeout);
      response = await http.Response.fromStream(streamed)
          .timeout(timeoutOverride ?? timeout);
    } on TimeoutException catch (e) {
      throw DavException(
        method: method,
        uri: uri,
        reason: 'timeout after ${timeoutOverride ?? timeout}',
        cause: e,
      );
    } on Object catch (e) {
      throw DavException(
          method: method, uri: uri, reason: 'transport failure', cause: e);
    }

    // A status in [statusCodesAsResults] is handed back instead of thrown.
    //
    // 412 and 409 are answers, not accidents: they are how a server says "your
    // base is stale" or "that path is taken", which §5.3 row 10 then turns
    // into a reclassification. Throwing them turned the engine's
    // `statusCode == 412` branch into code that cannot run — the branch was
    // covered by a unit test on the classifier and unreachable in production.
    if (response.statusCode >= 400 &&
        !statusCodesAsResults.contains(response.statusCode)) {
      throw DavException(
        method: method,
        uri: uri,
        reason: 'server returned ${response.statusCode}',
        statusCode: response.statusCode,
        body: _preview(response.bodyBytes),
        retryAfter: parseRetryAfter(response.headers['retry-after']),
      );
    }
    return response;
  }

  static String _preview(List<int> bytes, [int max = 600]) {
    if (bytes.isEmpty) return '';
    var text = const Utf8Decoder(allowMalformed: true).convert(bytes);
    if (text.length > max) text = '${text.substring(0, max)}…';
    return text;
  }

  /// `Retry-After` is either delay-seconds or an HTTP-date. An unparseable
  /// value is treated as absent rather than as zero, because honouring a
  /// zero would turn a server saying "come back later" into a hot loop.
  static Duration? parseRetryAfter(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);
    final when = HttpDateParser.tryParse(raw.trim());
    if (when == null) return null;
    final delta = when.difference(DateTime.now());
    return delta.isNegative ? Duration.zero : delta;
  }

  /// OPTIONS the base collection and read what the server advertises.
  ///
  /// This deliberately does *not* attempt to discover If-Match support. The
  /// only reliable probe is a write, and JotIt does not write in order to
  /// take its own capabilities dict — it learns from writes it needed anyway
  /// and takes the rest from the configured profile (v3.0 §6.3).
  Future<DavCapabilities> probe() async {
    final response = await _send('OPTIONS', baseUri);
    final davHeader = response.headers['dav'] ?? response.headers['DAV'];
    final classes = <String>{};
    if (davHeader != null) {
      for (final token in davHeader.split(',')) {
        final t = token.trim();
        if (t.isNotEmpty) classes.add(t);
      }
    }

    // CTag support is observable without writing: ask a collection for it and
    // see whether it comes back in a 200 propstat.
    var supportsCtag = false;
    var sawWeakEtag = false;
    try {
      final listing = await propfind('', depth: 0);
      final self = listing.self;
      supportsCtag = self?.ctag != null && self!.ctag!.isNotEmpty;
      if (listing.resources.any((r) => r.isWeakEtag)) sawWeakEtag = true;
    } on DavException catch (e) {
      // A server that cannot even answer PROPFIND depth 0 is not usable, but
      // reporting that is a configuration problem, not a probe failure.
      debugPrint('[dav] probe could not PROPFIND the base: $e');
    }

    return capabilities.copyWith(
      davClasses: classes.isEmpty ? null : classes,
      server: response.headers['server'],
      supportsCtag: supportsCtag,
      etagIsWeak: sawWeakEtag ? true : null,
      probedAt: DateTime.now().toUtc(),
    );
  }

  /// PROPFIND. [depth] is 0 or 1; the client refuses infinity because most
  /// servers answer 403 and because a full recursive walk would defeat the
  /// per-directory listing the sync engine is built around.
  Future<DavListing> propfind(String path, {int depth = 1}) async {
    if (depth != 0 && depth != 1) {
      throw ArgumentError.value(
          depth, 'depth', 'only 0 and 1 are used; infinity is not portable');
    }
    final uri = depth == 1 ? collectionUrlFor(path) : urlFor(path);
    final response = await _send('PROPFIND', uri, headers: <String, String>{
      'Depth': '$depth',
      'Content-Type': 'application/xml; charset="utf-8"',
    }, body: utf8.encode(propfindBody));

    if (response.statusCode != 207) {
      throw DavException(
        method: 'PROPFIND',
        uri: uri,
        reason: 'expected 207 Multi-Status',
        statusCode: response.statusCode,
        body: _preview(response.bodyBytes),
      );
    }
    return DavMultistatusParser.parse(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      davRoot: baseUri,
      queriedPath: path,
    );
  }

  /// Metadata for one resource, or null when it is not there.
  Future<DavResource?> stat(String path) async {
    try {
      final listing = await propfind(path, depth: 0);
      final target = listing.byPath(path);
      if (target != null) return target;
      // Some servers answer a depth-0 PROPFIND with a single response whose
      // href disagrees about the trailing slash. One entry means the answer
      // is unambiguous even if its path is not.
      return listing.resources.length == 1 ? listing.resources.first : null;
    } on DavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Direct children of a collection. Returns an empty list for a collection
  /// that exists but is empty, and null when it does not exist.
  Future<DavListing?> listCollection(String path) async {
    try {
      return await propfind(path, depth: 1);
    } on DavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Contents of a file, or null when it does not exist.
  Future<List<int>?> get(String path) async {
    final uri = urlFor(path);
    try {
      final response = await _send('GET', uri);
      return response.bodyBytes;
    } on DavException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Write a file.
  ///
  /// A [DavIfAbsent] precondition is what makes concurrent creation of the
  /// same path safe: whichever device arrives second gets 412 instead of
  /// silently overwriting the first device's note, and the decision matrix
  /// turns that into a path collision with two copies preserved.
  Future<DavPutResult> put(
    String path,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
  }) async {
    final uri = urlFor(path);
    final headers = <String, String>{
      'Content-Type': 'text/markdown; charset=utf-8',
      'Content-Length': '${bytes.length}',
    };
    switch (condition) {
      case DavUnconditional():
        break;
      case DavIfMatch(:final etag):
        // Sent verbatim. The quotes are part of the token; a server that
        // compares strictly will 412 a tag that lost its quotes, and a
        // server that compares loosely is exactly the server whose lost
        // updates ADR-8 exists to catch.
        if (capabilities.etagIsWeak) {
          throw ArgumentError(
              'server returns weak ETags; If-Match requires strong '
              'comparison and would fail forever',
              'condition');
        }
        if (!capabilities.supportsIfMatch) {
          throw ArgumentError(
              'refusing to send If-Match to a server known not to evaluate '
              'it: the write would be accepted regardless and the caller '
              'would believe it was protected',
              'condition');
        }
        headers['If-Match'] = etag;
      case DavIfAbsent():
        if (!capabilities.supportsIfNoneMatch) {
          throw ArgumentError('server is not known to evaluate If-None-Match',
              'condition');
        }
        headers['If-None-Match'] = '*';
    }

    final response = await _send('PUT', uri,
        headers: headers,
        body: bytes,
        timeoutOverride: const Duration(minutes: 2),
        // Returned, not thrown: the caller has to be able to tell "the server
        // refused this write because its base moved" (row 10) apart from "the
        // write failed" and act on it.
        statusCodesAsResults: const <int>{409, 412});

    return DavPutResult(
      statusCode: response.statusCode,
      etag: response.headers['etag'],
    );
  }

  /// Creates [collectionPath] and every missing folder above it.
  ///
  /// A `PUT` into a folder that does not exist comes back **409 Conflict**,
  /// and a 409 that nobody acts on means a brand new vault can never sync to
  /// an empty server: every note is refused, every round, forever. Walking
  /// down one segment at a time is what makes `notes/sub/note.md` work as
  /// well as `notes/note.md` — `MKCOL` of a deep path against a server that
  /// does not create intermediates answers 409 for the same reason.
  ///
  /// 201 means it was created, 405 means it was already there (RFC 4918
  /// §9.3.1), and both are success. Anything else is a real failure and is
  /// thrown: quietly carrying on would put the 409 straight back into the
  /// engine's "our base is stale" bucket, which is a lie.
  Future<void> ensureCollection(String collectionPath) async {
    final segments = collectionPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    var walked = '';
    for (final segment in segments) {
      walked = walked.isEmpty ? segment : '$walked/$segment';
      final response = await _send('MKCOL', collectionUrlFor(walked),
          statusCodesAsResults: const <int>{405});
      if (response.statusCode == 201 || response.statusCode == 405) continue;
      throw DavException(
        method: 'MKCOL',
        uri: collectionUrlFor(walked),
        reason: 'could not create the folder (HTTP ${response.statusCode})',
      );
    }
  }

  /// Delete a file. A missing file is success: the postcondition the caller
  /// cares about is "it is gone", not "it was there a moment ago".
  Future<bool> delete(String path, {String? ifMatch}) async {
    final uri = urlFor(path);
    final headers = <String, String>{};
    if (ifMatch != null) {
      if (!capabilities.supportsIfMatch) {
        throw ArgumentError(
            'refusing to send If-Match to a server known not to evaluate it',
            'ifMatch');
      }
      headers['If-Match'] = ifMatch;
    }
    try {
      await _send('DELETE', uri, headers: headers);
      return true;
    } on DavException catch (e) {
      if (e.statusCode == 404) return true;
      rethrow;
    }
  }

  /// MOVE inside the same collection. Used for renames; the whole point of
  /// ADR-2 is that a rename keeps the same `uid`, so the receiving device
  /// recognises the file it already knows under a new path.
  Future<void> move(String fromPath, String toPath,
      {bool overwrite = false}) async {
    final from = urlFor(fromPath);
    final to = urlFor(toPath);
    final headers = <String, String>{
      'Destination': to.toString(),
      'Overwrite': overwrite ? 'T' : 'F',
    };
    // A 412/409 here means somebody else moved or created the target in the
    // meantime. That is a real collision, not a transport failure, and the
    // decision matrix resolves it — so the exception propagates unchanged
    // rather than being retried or swallowed here.
    await _send('MOVE', from, headers: headers);
  }

  Future<void> close() async {
    if (_ownsHttpClient) _http.close();
  }
}

/// Minimal HTTP-date parsing, kept local so `dav_client` does not need
/// `dart:io` (and therefore stays testable on every platform).
///
/// RFC 9110 allows three forms: IMF-fixdate, obsolete RFC 850, and asctime.
/// `DateTime.parse` accepts the first two without complaint, which is all a
/// `Retry-After` header ever realistically carries.
class HttpDateParser {
  const HttpDateParser._();

  static DateTime? tryParse(String raw) {
    try {
      return DateTime.parse(raw).toUtc();
    } on FormatException {
      return null;
    }
  }
}