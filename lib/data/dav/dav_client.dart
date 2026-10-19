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
    Stream<List<int>>? bodyStream,
    int? contentLength,
    Duration? timeoutOverride,
    Set<int> statusCodesAsResults = const <int>{},
    void Function(int sent)? onProgress,
  }) async {
    final http.BaseRequest request;
    StreamSink<List<int>>? sink;
    if (bodyStream != null) {
      // §5.5: a large attachment is sent as a stream rather than as a
      // buffer. The alternative is not "slower" — it is that a 200 MB video
      // becomes a 200 MB allocation, which a phone will refuse and a desktop
      // will survive only until two of them overlap.
      final streamed = http.StreamedRequest(method, uri);
      // Declared up front. Some servers reject a chunked body outright, and
      // a `Content-Length` computed from the file costs nothing.
      streamed.contentLength = contentLength;
      sink = streamed.sink;
      request = streamed;
    } else {
      final buffered = http.Request(method, uri);
      if (body != null) buffered.bodyBytes = body;
      request = buffered;
    }
    request.headers.addAll(_auth);
    request.headers['User-Agent'] = _userAgent;
    if (headers != null) {
      for (final entry in headers.entries) {
        // `package:http` owns this one on a `StreamedRequest`; writing it
        // into `headers` as well makes the declared length and the declared
        // length disagree, and the server is the one that has to guess.
        if (entry.key.toLowerCase() == 'content-length') continue;
        request.headers[entry.key] = entry.value;
      }
    }

    final http.Response response;
    try {
      // Start the request **before** feeding it. `StreamedRequest`'s sink
      // buffers, and its `close()` future does not complete until a listener
      // is attached to drain it — so awaiting the close before calling `send`
      // is a deadlock, and it shows up as a sync round that never returns
      // rather than as an exception. The order below is the documented one.
      final sendFuture = _http.send(request);
      if (sink != null) {
        // `addStream`, not a manual `add` loop. The manual version looks
        // equivalent and is not: it ignores the backpressure future, so a
        // 200 MB body is queued in the controller's buffer while the socket
        // drains a few kilobytes at a time — and under that load the transfer
        // truncates mid-body and the server records a short file. `addStream`
        // applies the pause the transport asks for and waits for the drain.
        var sent = 0;
        try {
          // P1-8: both of these futures sat outside every timeout, so a
          // server that accepted the headers and then never read the body
          // hung the sync round forever. They now get the same budget as
          // the response wait, which `putStream` scales with the payload.
          await sink.addStream(bodyStream!.map((chunk) {
            sent += chunk.length;
            // Bytes rather than a percentage: a percentage needs a total the
            // caller may only learn partway through, and a progress bar that
            // has to be re-based mid-flight is worse than one that counts up.
            onProgress?.call(sent);
            return chunk;
          })).timeout(timeoutOverride ?? timeout);
          await sink.close().timeout(timeoutOverride ?? timeout);
        } on TimeoutException catch (e) {
          // Abort the in-flight request rather than leaving the socket open
          // for the server's own timeout to collect. The error the aborted
          // request produces is swallowed — this round has already failed,
          // and an unhandled error on the abandoned `send` future would take
          // down the isolate. The outer handler turns this into a
          // DavException the engine can report against the attachment.
          sendFuture.then((_) {}, onError: (Object _) {});
          try {
            sink.addError(e);
          } on Object {
            // Already closed or closing; nothing left to abort.
          }
          rethrow;
        }
      }
      final streamed = await sendFuture.timeout(timeoutOverride ?? timeout);
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
  ///
  /// [expectedLength] is a hint, not a requirement: it comes from the
  /// `Content-Length` a PROPFIND already reported, so sizing the wait costs
  /// nothing. It matters because the default 30 s is right for a note and
  /// hopeless for a large attachment — the same asymmetry
  /// [timeoutOverrideFor] exists to correct on the way up. Passing a wrong
  /// value cannot corrupt anything; it can only make the wait longer or
  /// shorter than ideal.
  Future<List<int>?> get(String path, {int? expectedLength}) async {
    final uri = urlFor(path);
    try {
      final response = await _send(
        'GET',
        uri,
        timeoutOverride:
            expectedLength == null ? null : timeoutOverrideFor(expectedLength),
      );
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
  ///
  /// [contentType] defaults to Markdown because that is what a vault path
  /// holds, and hard-coding it — which this used to do — silently mislabelled
  /// every attachment as `text/markdown`. That is not cosmetic: the server
  /// stores the type, hands it back on `GET`, and any other client reading the
  /// vault is told the picture is a text file.
  Future<DavPutResult> put(
    String path,
    List<int> bytes, {
    DavCondition condition = const DavUnconditional(),
    String contentType = 'text/markdown; charset=utf-8',
  }) async {
    final uri = urlFor(path);
    final headers = <String, String>{
      'Content-Type': contentType,
      'Content-Length': '${bytes.length}',
    };
    _applyCondition(headers, condition);

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

  /// Writes the precondition headers for [condition], or refuses to.
  ///
  /// Shared by the buffered and streamed writes so the two can never drift on
  /// which servers they will talk to. Both refusals are deliberate:
  ///
  ///  * `If-Match` to a weak-ETag server. RFC 7232 requires strong
  ///    comparison, so it can never succeed and `put` refuses to send it at
  ///    all — an unguarded engine threw out of every upload round. The Synology
  ///    box behind this returns `W/"31-..."` for files,
  ///  * `If-None-Match: *` to a server that does not evaluate it, for the same
  ///    reason: the write would be accepted regardless and the caller would
  ///    believe it was protected.
  void _applyCondition(Map<String, String> headers, DavCondition condition) {
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
  }

  /// Uploads a body as a stream (v3.0 §5.5).
  ///
  /// The distinction from [put] is not speed, it is that a 200 MB video is
  /// never a 200 MB `Uint8List`. A small file streams too, for one reason: a
  /// code path that only exists above a threshold is a code path that only
  /// runs on the day it is least welcome.
  ///
  /// Takes a `Stream` rather than a `File` on purpose. This file deliberately
  /// has no `dart:io` import — see `HttpDateParser` — so it stays testable on
  /// every platform. The caller owns opening the file and owns hashing it,
  /// which is the right way round anyway: the sync engine needs that hash to
  /// record a merge base, and computing it during the read means the bytes are
  /// touched once instead of twice.
  ///
  /// [contentLength] is declared up front rather than letting the request
  /// chunk: some servers reject a chunked body outright, and a length is one
  /// `stat()` away.
  Future<DavPutResult> putStream(
    String path,
    Stream<List<int>> content, {
    required int contentLength,
    String contentType = 'application/octet-stream',
    DavCondition condition = const DavUnconditional(),
    void Function(int sent)? onProgress,
    Duration? timeoutOverride,
  }) async {
    final uri = urlFor(path);
    final headers = <String, String>{
      'Content-Type': contentType,
      'Content-Length': '$contentLength',
    };
    _applyCondition(headers, condition);

    final response = await _send(
      'PUT',
      uri,
      headers: headers,
      bodyStream: content,
      contentLength: contentLength,
      timeoutOverride: timeoutOverride ?? timeoutOverrideFor(contentLength),
      statusCodesAsResults: const <int>{409, 412},
      onProgress: onProgress,
    );

    return DavPutResult(
      statusCode: response.statusCode,
      etag: response.headers['etag'],
    );
  }

  /// How long a body of [contentLength] bytes is allowed to take.
  ///
  /// The rate assumption is the whole content of this function, and it is
  /// **measured, not assumed**. Uploading to the Synology DSM box this project
  /// syncs against, over the LAN, with `curl` as the probe:
  ///
  /// | body | wall clock | throughput |
  /// |------|------------|------------|
  /// | 500 KB | 9.0 s | 54 KB/s |
  /// | 1 MB | 17.2 s | 57 KB/s |
  /// | 2 MB | 29.9 s | 65 KB/s |
  /// | 11.5 MB | 205 s | **56 KB/s** |
  ///
  /// That is roughly 3½ minutes per megabyte, so the budget below allots
  /// **45 seconds per megabyte** — about thirteen times the measured worst
  /// case, which is what a timeout needs to be: wrong in the direction of
  /// waiting rather than of giving up. The earlier `2000` ms/megabyte granted
  /// an 11 MB body 140 seconds and the transfer needed 205, so the client
  /// aborted a transfer the server was in the middle of accepting. The
  /// symptom is indistinguishable from a network fault — the attachment is
  /// simply absent, with an error that says "timeout" and nothing about which
  /// side was too slow.
  ///
  /// The two-minute floor stays, and so does the one-hour cap: past an hour a
  /// stalled connection and a genuinely enormous file are indistinguishable,
  /// and an unbounded wait turns one bad socket into a sync round that never
  /// returns.
  ///
  /// Rounded **up**, deliberately. An 11.5 MB body is 10 whole megabytes plus
  /// half, and `~/` threw that half away: the budget was calculated for 10 MB
  /// and the body was 11.5 MB. Truncating here is how a function that scales
  /// with the payload still under-grants by 13% at exactly the sizes where
  /// the margin is already thinnest.
  static Duration timeoutOverrideFor(int contentLength) {
    final megabytes =
        (contentLength + (1024 * 1024 - 1)) ~/ (1024 * 1024);
    final ms = 120000 + megabytes * 45000;
    return Duration(milliseconds: ms.clamp(120000, 3600000).toInt());
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
  ///
  /// [ifMatch] is honoured only when the server can actually evaluate it:
  ///
  ///  * RFC 7232 compares `If-Match` **strongly**, so a weak-ETag server
  ///    answers 412 forever no matter how fresh the tag is;
  ///  * a server that does not evaluate the header accepts the delete
  ///    regardless, so sending one would have the caller believe a
  ///    precondition was honoured when it never left the client.
  ///
  /// In both cases this degrades to an unconditional DELETE — the same
  /// trade the engine's `_conditionFor` makes for writes, since §6.3
  /// accepts the narrow lost-update window on the nginx-dav and weak-ETag
  /// profiles. It deliberately does **not** throw: the ArgumentError this
  /// used to raise escaped every `on DavException` handler in the engine
  /// and took the whole round down with it, on a delete that was perfectly
  /// safe to perform.
  Future<bool> delete(String path, {String? ifMatch}) async {
    final uri = urlFor(path);
    final headers = <String, String>{};
    if (ifMatch != null &&
        ifMatch.isNotEmpty &&
        capabilities.supportsIfMatch &&
        !capabilities.etagIsWeak) {
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
