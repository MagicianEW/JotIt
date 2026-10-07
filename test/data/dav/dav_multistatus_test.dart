import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/dav/dav_multistatus.dart';

/// Wraps a multistatus body with the given default/prefixed namespace so the
/// same assertions run against every serialisation style a real server emits.
String multistatus(String inner,
        {String prefix = 'D', bool defaultNs = false, bool extraNs = false}) {
  final ns = extraNs
      ? ' xmlns:D="DAV:" xmlns:oc="http://owncloud.org/ns"'
      : defaultNs
          ? ' xmlns="DAV:"'
          : ' xmlns:D="DAV:"';
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<${prefix.isEmpty ? '' : '$prefix:'}multistatus$ns>$inner'
      '</${prefix.isEmpty ? '' : '$prefix:'}multistatus>';
}

String response({
  required String href,
  String etag = '"abc"',
  String? ctag,
  String resourcetype = '',
  String extra = '',
  int? length,
  bool omitEtag = false,
}) {
  return '<response>'
      '<href>$href</href>'
      '<propstat><prop>'
      '$resourcetype'
      '${omitEtag ? '' : '<getetag>$etag</getetag>'}'
      '${ctag == null ? '' : '<getctag>$ctag</getctag>'}'
      '${length == null ? '' : '<getcontentlength>$length</getcontentlength>'}'
      '<getlastmodified>Wed, 07 Oct 2026 09:59:49 GMT</getlastmodified>'
      '<getcontenttype>text/markdown; charset=utf-8</getcontenttype>'
      '<displayname>x</displayname>'
      '$extra'
      '</prop><status>HTTP/1.1 200 OK</status></propstat>'
      '</response>';
}

void main() {
  // Every listing below is parsed against this DAV root. Paths in the
  // assertions are therefore DAV-root relative ("notes/a.md"), never
  // collection relative ("a.md") — the client compares them against paths it
  // derives from `sync_meta`, so the two must never be confused.
  const rootUri = 'http://h/dav/';

  group('namespace handling', () {
    // The bug this guards: a parser that matches the *prefixed* name works
    // against Apache and silently returns nothing against a server that
    // picked `d:` or used a default namespace. Change detection that quietly
    // sees an empty remote is indistinguishable from "nothing to sync", so it
    // would report every device as in sync forever.
    final bodies = <String, String>{
      'D: prefix': multistatus(
          response(href: '/dav/notes/a.md'),
          prefix: 'D'),
      'd: prefix': multistatus(
          response(href: '/dav/notes/a.md'),
          prefix: 'd'),
      'default namespace': multistatus(
          response(href: '/dav/notes/a.md'),
          defaultNs: true),
      'no namespace at all': multistatus(
          response(href: '/dav/notes/a.md'),
          defaultNs: false).replaceAll(' xmlns:D="DAV:"', ''),
      'plus a foreign namespace': multistatus(
          response(href: '/dav/notes/a.md', extra: '<oc:permissions>RDNVCK</oc:permissions>'),
          extraNs: true),
    };

    bodies.forEach((style, body) {
      test('parses a file entry written with $style', () {
        final listing = DavMultistatusParser.parse(body,
            davRoot: Uri.parse(rootUri), queriedPath: 'notes');
        final file = listing.byPath('notes/a.md');
        expect(file, isNotNull, reason: 'style: $style');
        expect(file!.etag, '"abc"');
        expect(file.isCollection, isFalse);
        expect(file.contentLength, isNull);
      });
    });
  });

  group('href forms', () {
    // All three appear in the wild, sometimes from one server on different
    // routes. A parser that only handles one of them silently drops files.
    test('absolute URL', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: 'http://h/dav/notes/a.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md'), isNotNull);
    });

    test('absolute path', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md'), isNotNull);
    });

    test('relative to the queried collection', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: 'a.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md'), isNotNull);
    });

    test('the queried collection maps to its own DAV-root path', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(
              href: '/dav/notes/',
              resourcetype: '<resourcetype><collection/></resourcetype>',
              ctag: '"tag1"')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.self?.path, 'notes');
      expect(listing.self?.ctag, '"tag1"');
      expect(listing.self?.isCollection, isTrue);
    });

    test('the DAV root itself is the empty path', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(
              href: '/dav/',
              resourcetype: '<resourcetype><collection/></resourcetype>',
              ctag: '"rt"')),
          davRoot: Uri.parse(rootUri), queriedPath: '');
      expect(listing.self?.path, '');
      expect(listing.collectionCtag, '"rt"');
    });

    test('a depth-0 PROPFIND on one file identifies that file', () {
      // The case that forced paths to be DAV-root relative: with a single
      // response and collection-relative paths the client could not tell
      // whether it had asked about `a.md` or `b.md`, only that it got one
      // answer. `stat()` depends on naming it correctly.
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/同步/引擎.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes/同步/引擎.md');
      expect(listing.resources, hasLength(1));
      expect(listing.byPath('notes/同步/引擎.md'), isNotNull);
      expect(listing.children, isEmpty);
    });
  });

  group('percent encoding', () {
    test('decodes CJK and spaces in a filename', () {
      // The literal is generated rather than hand-written: hand-rolled UTF-8
      // percent-encoding is wrong often enough to waste a debugging session.
      // The authoritative CJK check is the live-server round trip in
      // dav_client_test.dart, where the encoder under test is Node's
      // encodeURIComponent rather than Dart's.
      const name = '同步引擎.md';
      final encoded = Uri.encodeComponent(name);
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/$encoded')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/$name'), isNotNull);
    });

    test('decodes a space in a filename', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/my%20note.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/my note.md'), isNotNull);
    });

    test('an encoded slash stays inside one segment', () {
      // %2F is a literal slash in a *filename*. Decoding the whole path
      // before splitting would invent a directory that does not exist and
      // then try to write into it.
      expect(DavMultistatusParser.normalizePath('notes/a%2Fb.md'), 'notes/a/b.md');
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a%2Fb.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a/b.md'), isNotNull);
    });

    test('a bare percent sign does not take the round down', () {
      expect(DavMultistatusParser.normalizePath('100%-done.md'), '100%-done.md');
    });
  });

  group('etag handling', () {
    test('is kept verbatim with its quotes', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md', etag: '"2f-1a1b2c"')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md')?.etag, '"2f-1a1b2c"');
    });

    test('recognises a weak etag', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md', etag: 'W/"weak"')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      final r = listing.byPath('notes/a.md')!;
      expect(r.isWeakEtag, isTrue);
      expect(r.strongForm, '"weak"');
      expect(r.etag, 'W/"weak"', reason: 'strongForm must not be sent back');
    });

    test('a strong etag is not reported weak', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md')),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md')!.isWeakEtag, isFalse);
      expect(listing.byPath('notes/a.md')!.strongForm, '"abc"');
    });
  });

  group('degradation', () {
    // A server that will not report getetag must degrade JotIt to content
    // hash comparison. It must NOT abort the round, because aborting would
    // strand every note behind one server quirk.
    test('a 404 propstat becomes a missing property, not a crash', () {
      final body = multistatus(
          '<response><href>/dav/notes/a.md</href>'
          '<propstat><prop><getetag/><getctag/></prop>'
          '<status>HTTP/1.1 404 Not Found</status></propstat>'
          '<propstat><prop><resourcetype/><getcontentlength/></prop>'
          '<status>HTTP/1.1 200 OK</status></propstat>'
          '</response>');
      final listing = DavMultistatusParser.parse(body,
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      final r = listing.byPath('notes/a.md')!;
      expect(r.etag, isNull);
      expect(r.missingProps, containsAll(<String>['getetag', 'getctag']));
      expect(r.isCollection, isFalse);
      expect(listing.missing.single.properties, contains('getetag'));
    });

    test('a resource with no etag still lists', () {
      final listing = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md', omitEtag: true)),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.byPath('notes/a.md'), isNotNull);
      expect(listing.byPath('notes/a.md')!.etag, isNull);
    });
  });

  group('listing shape', () {
    final body = multistatus(response(
        href: '/dav/notes/',
        resourcetype: '<resourcetype><collection/></resourcetype>',
        ctag: '"c1"') +
        response(href: '/dav/notes/a.md') +
        response(href: '/dav/notes/sub/',
            resourcetype: '<resourcetype><collection/></resourcetype>') +
        response(href: '/dav/notes/b.md', etag: '"b2"'));
    final listing = DavMultistatusParser.parse(body,
        davRoot: Uri.parse(rootUri), queriedPath: 'notes');

    test('children excludes the collection itself', () {
      expect(listing.children.map((r) => r.path),
          unorderedEquals(<String>['notes/a.md', 'notes/sub', 'notes/b.md']));
    });

    test('files and collections are separated', () {
      expect(listing.files.map((r) => r.path),
          unorderedEquals(<String>['notes/a.md', 'notes/b.md']));
      expect(listing.collections.map((r) => r.path),
          containsAll(<String>['notes', 'notes/sub']));
    });

    test('content length is parsed when present', () {
      final withLength = DavMultistatusParser.parse(
          multistatus(response(href: '/dav/notes/a.md', length: 412)),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(withLength.byPath('notes/a.md')!.contentLength, 412);
    });

    test('last modified is parsed as UTC', () {
      expect(listing.byPath('notes/a.md')!.lastModified, isNotNull);
      expect(listing.byPath('notes/a.md')!.lastModified!.isUtc, isTrue);
    });
  });

  group('malformed input', () {
    test('invalid XML raises FormatException', () {
      expect(
        () => DavMultistatusParser.parse('<multistatus><response>',
            davRoot: Uri.parse(rootUri), queriedPath: 'notes'),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty body parses to nothing rather than throwing', () {
      final listing = DavMultistatusParser.parse(
          multistatus(''), davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.resources, isEmpty);
      expect(listing.children, isEmpty);
    });

    test('a response with no href is skipped', () {
      final listing = DavMultistatusParser.parse(
          multistatus('<response><propstat/></response>'),
          davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.resources, isEmpty);
    });
  });

  group('normalizePath', () {
    test('collapses redundant and leading slashes', () {
      expect(DavMultistatusParser.normalizePath('/a//b/'), 'a/b');
      expect(DavMultistatusParser.normalizePath(''), '');
    });
  });

  group('parseHttpDate', () {
    // `HttpDate.parse` throws rather than returning null, so the tolerance is
    // explicit. One malformed `getlastmodified` must not take down a whole
    // listing — the engine reads a null mtime as "unknown", never "changed".
    test('parses RFC 1123 as UTC', () {
      expect(
        DavMultistatusParser.parseHttpDate('Wed, 07 Oct 2026 09:59:49 GMT'),
        DateTime.utc(2026, 10, 7, 9, 59, 49),
      );
    });

    test('RFC 7231 permits only a literal GMT, so +0200 is malformed', () {
      // HTTP dates never carry a numeric offset. Returning null beats
      // guessing a zone the header never stated — a wrong "last modified"
      // is a spurious change, and a spurious change is an upload.
      expect(
        DavMultistatusParser.parseHttpDate('Wed, 07 Oct 2026 11:59:49 +0200'),
        isNull,
      );
    });

    test('accepts RFC 850 and asctime forms', () {
      expect(DavMultistatusParser.parseHttpDate(
              'Wednesday, 07-Oct-26 09:59:49 GMT'),
          isNotNull);
      expect(DavMultistatusParser.parseHttpDate(
              'Wed Oct  7 09:59:49 2026'),
          isNotNull);
    });

    test('a malformed date is null, not an exception', () {
      for (final bad in ['', '   ', 'not a date', '2026-10-07', '0']) {
        expect(DavMultistatusParser.parseHttpDate(bad), isNull, reason: bad);
      }
      expect(DavMultistatusParser.parseHttpDate(null), isNull);
    });

    test('a malformed date does not lose the resource it belongs to', () {
      final body = multistatus(
        '<response><href>/dav/notes/a.md</href><propstat><prop>'
        '<getetag>"abc"</getetag>'
        '<getlastmodified>garbage</getlastmodified>'
        '</prop><status>HTTP/1.1 200 OK</status></propstat></response>',
      );
      final listing = DavMultistatusParser.parse(
          body, davRoot: Uri.parse(rootUri), queriedPath: 'notes');
      expect(listing.resources.length, 1);
      expect(listing.resources.single.path, 'notes/a.md');
      expect(listing.resources.single.lastModified, isNull);
      expect(listing.resources.single.etag, isNotNull,
          reason: 'the etag is what change detection actually needs');
    });
  });
}