import 'dart:io' show HttpDate;

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// One `<D:response>` entry from a PROPFIND multistatus.
@immutable
class DavResource {
  const DavResource({
    required this.path,
    required this.href,
    required this.isCollection,
    this.etag,
    this.ctag,
    this.contentLength,
    this.lastModified,
    this.contentType,
    this.displayName,
    this.foundProps = const <String>{},
    this.missingProps = const <String>{},
  });

  /// Decoded, slash-normalised path relative to the DAV root. `''` is the
  /// root collection. Never has a leading or trailing slash, except the
  /// empty root itself.
  final String path;

  /// The `<D:href>` exactly as the server sent it, still percent-encoded.
  /// Kept because it is the only thing guaranteed to be accepted back in a
  /// `Destination` header.
  final String href;

  final bool isCollection;

  /// The entity-tag **verbatim, including its surrounding quotes**.
  ///
  /// Never parse this. Never normalise the quoting. Never reformat it. It is
  /// an opaque token whose only meaning is "did this byte-identical thing
  /// change", and the server is free to change its shape at any time — as
  /// indeed Synology's `size-hex-mtimeHex` already differs from nginx's.
  final String? etag;

  /// Collection-level change token. Absent on most servers.
  final String? ctag;

  final int? contentLength;
  final DateTime? lastModified;
  final String? contentType;
  final String? displayName;

  /// Local names of properties the server actually returned (propstat 200).
  final Set<String> foundProps;

  /// Local names the server explicitly reported as missing (propstat 404).
  final Set<String> missingProps;

  bool get exists => true;

  /// A `W/`-prefixed tag. RFC 7232 §3.2 requires *strong* comparison for
  /// If-Match, so a weak tag can never satisfy one — an If-Match sent
  /// against a weak-etag server fails forever unless the server is
  /// lenient. Callers must check this and degrade to hash comparison.
  bool get isWeakEtag => etag != null && etag!.startsWith('W/');

  /// The tag with any `W/` prefix removed, for *display and comparison only*.
  /// Never send this back in a conditional header.
  String? get strongForm => etag?.startsWith('W/') == true
      ? etag!.substring(2)
      : etag;

  @override
  String toString() =>
      'DavResource($path, ${isCollection ? 'dir' : 'file'}, etag: $etag)';
}

/// A property the server refused to report. JotIt degrades rather than dies:
/// a missing `getetag` means "compare content hashes instead", not "abort the
/// round", because aborting would strand the user's notes behind a server
/// quirk.
@immutable
class DavMissingProperty {
  const DavMissingProperty({required this.path, required this.properties});
  final String path;
  final Set<String> properties;
  @override
  String toString() => 'DavMissingProperty($path: $properties)';
}

/// A parsed 207 Multi-Status.
///
/// Every [DavResource.path] is relative to the **DAV root**, never to the
/// collection that was queried. That matters for the one case that is easy to
/// get wrong: a Depth-0 PROPFIND on a single file returns exactly one
/// resource, and if paths were relative to the query the client could not
/// tell whether that resource was `a.md` or `b.md` — it would only know it
/// was "the thing I asked about". DAV-root-relative paths are unambiguous,
/// so they are compared, stored and cached the same way everywhere.
@immutable
class DavListing {
  const DavListing({
    required this.queriedPath,
    required this.resources,
    this.missing = const <DavMissingProperty>[],
  });

  /// The collection the client asked about, DAV-root-relative. `''` is the
  /// root itself.
  final String queriedPath;

  /// Every resource the server reported, including the queried collection
  /// when it reported itself.
  final List<DavResource> resources;

  final List<DavMissingProperty> missing;

  DavResource? byPath(String path) {
    for (final r in resources) {
      if (r.path == path) return r;
    }
    return null;
  }

  /// Everything except the queried collection itself.
  List<DavResource> get children =>
      resources.where((r) => r.path != queriedPath).toList(growable: false);

  Iterable<DavResource> get files =>
      resources.where((r) => !r.isCollection && r.path != queriedPath);

  Iterable<DavResource> get collections =>
      resources.where((r) => r.isCollection);

  /// The queried collection's own resource, when the server reported it.
  DavResource? get self => byPath(queriedPath);

  String? get collectionCtag => self?.ctag;
}

/// Parser for DAV multistatus bodies.
///
/// Every lookup matches on the *local* name, never the prefixed one. Synology,
/// Nextcloud and nginx-dav all serialise `DAV:` differently and some add extra
/// namespaces, but the local names are stable — a parser that matches
/// `D:response` against Apache's `<D:response>` works and the same parser
/// silently returns nothing against a server that chose `d:`. Matching
/// `name.local` costs nothing and removes an entire class of "works on my
/// machine" sync failures.
class DavMultistatusParser {
  const DavMultistatusParser._();

  static DavListing parse(
    String body, {
    required Uri davRoot,
    required String queriedPath,
  }) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw FormatException('PROPFIND response is not valid XML: ${e.message}',
          body.length > 300 ? body.substring(0, 300) : body);
    }

    final resources = <DavResource>[];
    final missing = <DavMissingProperty>[];

    for (final response in _byLocalName(doc.rootElement, 'response')) {
      final href = response.children
              .whereType<XmlElement>()
              .where((e) => e.name.local == 'href')
              .map((e) => e.innerText.trim())
              .firstOrNull ??
          '';
      if (href.isEmpty) continue;

      final path =
          normalizePath(relativePathOf(href, davRoot.path, queriedPath));

      final found = <String>{};
      final absent = <String>{};
      final props = <String, String>{};
      var isCollection = false;

      for (final propstat in _byLocalName(response, 'propstat')) {
        // Only a 200 propstat counts as "the server reported this".
        final status = propstat.children
                .whereType<XmlElement>()
                .where((e) => e.name.local == 'status')
                .map((e) => e.innerText)
                .firstOrNull ??
            '';
        final isOk = status.contains(' 200 ');
        for (final prop in _byLocalName(propstat, 'prop')) {
          for (final child in prop.children.whereType<XmlElement>()) {
            if (isOk) {
              found.add(child.name.local);
              props[child.name.local] = child.innerText.trim();
              if (child.name.local == 'resourcetype' &&
                  _byLocalName(child, 'collection').isNotEmpty) {
                isCollection = true;
              }
            } else {
              absent.add(child.name.local);
            }
          }
        }
      }

      if (absent.isNotEmpty) {
        missing.add(
            DavMissingProperty(path: path, properties: Set.unmodifiable(absent)));
      }
      if (found.isEmpty && absent.isEmpty) continue;

      resources.add(DavResource(
        path: path,
        href: href,
        isCollection: isCollection,
        etag: props['getetag'],
        ctag: props['getctag'],
        contentLength: int.tryParse(props['getcontentlength'] ?? ''),
        lastModified: parseHttpDate(props['getlastmodified']),
        contentType: props['getcontenttype'],
        displayName: props['displayname'] ?? '',
        foundProps: Set.unmodifiable(found),
        missingProps: Set.unmodifiable(absent),
      ));
    }

    return DavListing(
      queriedPath: normalizePath(queriedPath),
      resources: List.unmodifiable(resources),
      missing: List.unmodifiable(missing),
    );
  }

  /// Decodes an `<D:href>` and returns the path relative to the DAV root.
  ///
  /// Hrefs come in three shapes and all of them are seen in the wild, sometimes
  /// from the same server on different routes: an absolute URL
  /// (`http://host/dav/notes/a.md`), an absolute path (`/dav/notes/a.md`), or
  /// a relative reference (`a.md`). A relative one is resolved against the
  /// *queried* resource, which is what HTTP says — resolving it against the
  /// DAV root instead would silently drop a file into the wrong directory and
  /// nothing would report an error.
  ///
  /// The root is matched with and without a trailing slash, because servers
  /// disagree about which they send.
  static String relativePathOf(
      String href, String rootPath, String queriedPath) {
    final Uri uri;
    try {
      uri = Uri.parse(href);
    } on FormatException {
      return href;
    }

    final root = rootPath.endsWith('/')
        ? rootPath.substring(0, rootPath.length - 1)
        : rootPath;
    final prefix = root.isEmpty ? '/' : '$root/';

    var path = uri.hasScheme ? uri.path : href;
    if (!uri.hasScheme && !path.startsWith('/')) {
      final dir = queriedPath.isEmpty ? '' : '$queriedPath/';
      path = '$prefix$dir$path';
    }

    if (path == root || path == prefix) return '';
    if (path.startsWith(prefix)) path = path.substring(prefix.length);
    return path;
  }

  /// Percent-decodes each segment separately, so an encoded `%2F` inside a
  /// filename stays a literal slash in a name rather than becoming a
  /// directory boundary.
  static String normalizePath(String path) {
    if (path.isEmpty) return '';
    return path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((s) {
          try {
            return Uri.decodeComponent(s);
          }
          // `Uri.decodeComponent` signals a malformed escape with
          // ArgumentError, not FormatException — catching only the latter
          // lets one stray "%" from a server abort an entire sync round.
          // A name we cannot decode is still a name; keeping it raw is
          // strictly better than dropping the file.
          on Object {
            return s;
          }
        })
        .join('/');
  }

  /// RFC 1123 / RFC 850 / asctime, in that order of likelihood.
  static DateTime? parseHttpDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = HttpDate.parse(raw);
    return parsed == null ? null : parsed.toUtc();
  }

  static Iterable<XmlElement> _byLocalName(XmlNode root, String local) =>
      root.descendants.whereType<XmlElement>().where((e) => e.name.local == local);
}