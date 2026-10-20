// A small WebDAV server for JotIt's integration tests.
//
// The Synology box on the LAN refuses our credentials, and even a working
// server would only ever exercise ONE capability profile. v3.0 §6.3 requires
// testing three (Nextcloud / Synology / nginx-dav), and the differences that
// actually bite — CTag support and `If-Match` conditional PUT — are exactly
// the ones a real server is least willing to be told about. So this server
// takes its capabilities as flags.
//
//   node tools/webdav-test-server.mjs --root ./.webdav --port 35116
//   node tools/webdav-test-server.mjs --port 0        # any free port
//   node tools/webdav-test-server.mjs --no-ctag      # Synology-like
//   node tools/webdav-test-server.mjs --no-if-match   # nginx-dav-like
//   node tools/webdav-test-server.mjs --no-if-none-match
//
// ETag values are opaque and deliberately change whenever content changes;
// nothing in JotIt is allowed to parse them.
//
// `--port 0` asks the OS for a free port. The endpoint that was actually
// bound is printed, so a caller that cannot pick a port itself can read it
// back instead of guessing one that may already be taken.

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const argv = parseArgs(process.argv.slice(2));
const ROOT = path.resolve(argv.root ?? '.webdav');
const PORT = Number(argv.port ?? 35116);
const HOST = argv.host ?? '127.0.0.1';
const USER = argv.user ?? 'testuser';
const PASS = argv.pass ?? 'test';
const BASE = '/' + (argv.base ?? 'dav').replace(/^\/+|\/+$/g, '');
const SUPPORTS_CTAG = argv['no-ctag'] !== true;
const SUPPORTS_IF_MATCH = argv['no-if-match'] !== true;
const SUPPORTS_IF_NONE_MATCH = argv['no-if-none-match'] !== true;
const STRICT_COLLECTIONS = argv['strict-collections'] === true;
const VERBOSE = argv.verbose === true;

fs.mkdirSync(ROOT, { recursive: true });

// ---------------------------------------------------------------- helpers

function parseArgs(list) {
  const out = {};
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = list[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    }
  }
  return out;
}

function decodePath(href) {
  let p = decodeURIComponent(href.split('?')[0]);
  if (!p.startsWith(BASE)) return null;
  p = p.slice(BASE.length);
  if (p === '' || p === '/') p = '/';
  if (!p.endsWith('/')) p += '/';
  return p;
}

/** Map a request path to a real path, refusing anything that escapes ROOT. */
function resolve(p) {
  const segments = [];
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue;
    if (seg === '..') return null;
    segments.push(seg);
  }
  const abs = path.join(ROOT, ...segments);
  const normalized = path.resolve(abs);
  if (normalized !== ROOT && !normalized.startsWith(ROOT + path.sep)) return null;
  return { abs: normalized, isRoot: normalized === ROOT };
}

function etagFor(stat) {
  // Opaque by contract. Never parse this client-side. mtimeMs is a float on
  // Windows, so floor it — "1a115cdf49a.adb" is a legal but bizarre token.
  const mtime = Math.floor(stat.mtimeMs);
  return `"${stat.size.toString(16)}-${mtime.toString(16)}"`;
}

function httpDate(ms) {
  return new Date(ms).toUTCString();
}

function xmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function hrefFor(p, isCollection) {
  const encoded = p
    .split('/')
    .filter(Boolean)
    .map((s) => encodeURIComponent(s))
    .join('/');
  return `${BASE}/${encoded}${isCollection && p !== '/' ? '/' : ''}`;
}

/** Collection ctag: one token per subtree state, at the collection level. */
function ctagFor(abs) {
  const hash = crypto.createHash('sha1');
  const walk = (dir) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(dir, e.name);
      const rel = path.relative(ROOT, full).replace(/\\/g, '/');
      if (e.isDirectory()) { hash.update(`d${rel}\0`); walk(full); }
      else {
        try {
          const st = fs.statSync(full);
          hash.update(`f${rel}:${st.size}:${st.mtimeMs}\0`);
        } catch { /* raced with a delete */ }
      }
    }
  };
  walk(abs);
  return `"${hash.digest('hex').slice(0, 20)}"`;
}

function send(res, code, body, headers = {}) {
  res.writeHead(code, { 'Server': 'JotItTestDAV/1.0', ...headers });
  if (body === undefined || body === null) res.end();
  else res.end(body);
}

function sendPropfindError(res, status, reason) {
  send(res, status, reason, { 'Content-Type': 'text/plain; charset=utf-8' });
}

function readBody(req) {
  return new Promise((resolvePromise, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolvePromise(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

// ------------------------------------------------------------------ auth

function authorized(req) {
  const header = req.headers['authorization'] ?? '';
  if (!header.startsWith('Basic ')) return false;
  const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
  const idx = decoded.indexOf(':');
  const user = decoded.slice(0, idx);
  const pass = decoded.slice(idx + 1);
  return timingSafeEqual(user, USER) && timingSafeEqual(pass, PASS);
}

function timingSafeEqual(a, b) {
  const ab = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

// -------------------------------------------------------------- PROPFIND

function propResponse(p, abs, isCollection, stat, depth, requested) {
  const href = hrefFor(p, isCollection);
  const props = [];

  const want = (name) => requested.size === 0 || requested.has(name);

  if (want('resourcetype')) {
    props.push(isCollection
      ? '<D:resourcetype><D:collection/></D:resourcetype>'
      : '<D:resourcetype/>');
  }
  if (want('displayname')) {
    props.push(`<D:displayname>${xmlEscape(path.basename(abs) || '/')}</D:displayname>`);
  }
  if (want('getcontentlength')) {
    props.push(`<D:getcontentlength>${isCollection ? 0 : stat.size}</D:getcontentlength>`);
  }
  if (want('getlastmodified')) {
    props.push(`<D:getlastmodified>${xmlEscape(httpDate(stat.mtimeMs))}</D:getlastmodified>`);
  }
  if (want('getetag')) {
    props.push(`<D:getetag>${xmlEscape(etagFor(stat))}</D:getetag>`);
  }
  // Synology and Apache dav omit getctag entirely; JotIt must degrade to a
  // full PROPFIND rather than treating a missing tag as "nothing changed".
  if (SUPPORTS_CTAG && want('getctag') && isCollection) {
    props.push(`<D:getctag>${xmlEscape(ctagFor(abs))}</D:getctag>`);
  }
  if (want('getcontenttype')) {
    props.push(`<D:getcontenttype>${xmlEscape(contentType(abs))}</D:getcontenttype>`);
  }

  return [
    '  <D:response>',
    `    <D:href>${xmlEscape(href)}</D:href>`,
    '    <D:propstat>',
    '      <D:prop>',
    ...props.map((x) => '        ' + x),
    '      </D:prop>',
    '      <D:status>HTTP/1.1 200 OK</D:status>',
    '    </D:propstat>',
    '  </D:response>',
  ].join('\n');
}

function contentType(abs) {
  const ext = path.extname(abs).toLowerCase();
  return ({
    '.md': 'text/markdown; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
    '.pdf': 'application/pdf',
  })[ext] ?? 'application/octet-stream';
}

function parseRequestedProps(xml) {
  const out = new Set();
  if (!xml) return out;
  const propBlock = xml.match(/<(?:[A-Za-z0-9]+:)?prop(?:\s[^>]*)?>([\s\S]*?)<\/(?:[A-Za-z0-9]+:)?prop>/i);
  if (!propBlock) {
    // <allprop/> or empty body means "send everything we have".
    return out;
  }
  for (const m of propBlock[1].matchAll(/<(?:[A-Za-z0-9]+:)?([A-Za-z0-9-]+)\s*\/>/g)) {
    out.add(m[1].toLowerCase());
  }
  return out;
}

async function handlePropfind(req, res, p, info) {
  const depth = String(req.headers.depth ?? '1');
  if (depth === 'infinity') {
    // Refused by most real servers; JotIt must never rely on it.
    return sendPropfindError(res, 403, 'PROPFIND Depth: infinity is disabled');
  }
  const body = await readBody(req);
  const requested = parseRequestedProps(body.toString('utf8'));

  let stat;
  try { stat = await fsp.stat(info.abs); } catch { return send(res, 404, 'Not found'); }

  const lines = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<D:multistatus xmlns:D="DAV:">',
    propResponse(p, info.abs, stat.isDirectory(), stat, depth, requested),
  ];

  // PROPFIND on a non-collection is legal (RFC 4918 §9.1) and Apache,
  // nginx-dav and Synology all answer it with a 207 naming just that
  // resource. Answering 404 here instead would make the test server
  // stricter than every server it is standing in for, and clients would
  // "pass" against it while failing on real hardware.
  if (depth === '1' && stat.isDirectory()) {
    let entries = [];
    try { entries = await fsp.readdir(info.abs, { withFileTypes: true }); } catch { entries = []; }
    for (const e of entries) {
      const childAbs = path.join(info.abs, e.name);
      let childStat;
      try { childStat = await fsp.stat(childAbs); } catch { continue; }
      const isCollection = childStat.isDirectory();
      const childPath = p === '/' ? `/${e.name}` : `${p}${e.name}`;
      lines.push(propResponse(childPath, childAbs, isCollection, childStat, depth, requested));
    }
  }

  lines.push('</D:multistatus>');
  send(res, 207, lines.join('\n'), {
    'Content-Type': 'application/xml; charset="utf-8"',
    DAV: '1, 2',
  });
}

// ------------------------------------------------------------------ verbs

async function handleGet(req, res, info) {
  let stat;
  try { stat = await fsp.stat(info.abs); } catch { return send(res, 404, 'Not found'); }
  if (stat.isDirectory()) return send(res, 405, 'Cannot GET a collection');
  const data = await fsp.readFile(info.abs);
  send(res, 200, data, {
    'Content-Type': contentType(info.abs),
    ETag: etagFor(stat),
    'Last-Modified': httpDate(stat.mtimeMs),
    'Content-Length': String(data.length),
  });
}

async function handlePut(req, res, p, info) {
  let existing = null;
  try { existing = await fsp.stat(info.abs); } catch { /* new file */ }

  if (existing?.isDirectory()) return send(res, 405, 'Cannot PUT over a collection');

  const ifMatch = req.headers['if-match'];
  if (ifMatch === undefined && SUPPORTS_IF_MATCH) {
    if (VERBOSE) console.log('[dav] ignoring If-Match (server has no support)');
  } else if (ifMatch !== undefined && SUPPORTS_IF_MATCH && existing === null) {
    // RFC 7232: If-Match on a resource that does not exist never matches.
    // JotIt must therefore not send a precondition when creating a file —
    // doing so would make every first upload of a new note fail.
    if (VERBOSE) console.log('[dav] 412 If-Match against a non-existent resource');
    return send(res, 412, 'Precondition Failed');
  } else if (ifMatch !== undefined && SUPPORTS_IF_MATCH) {
    const current = etagFor(existing);
    const wanted = String(ifMatch).trim();
    const ok = wanted === '*' ||
      wanted.split(',').map((s) => s.trim()).some((s) => s === current);
    if (!ok) {
      if (VERBOSE) console.log(`[dav] 412 If-Match ${wanted} != ${current}`);
      return send(res, 412, 'Precondition Failed');
    }
  }

  // If-None-Match: * is the atomic "create only if absent" primitive. Two
  // devices racing to create the same path must not both succeed, or ADR-2's
  // path-collision detection never gets a chance to run.
  const ifNoneMatch = req.headers['if-none-match'];
  if (ifNoneMatch !== undefined && SUPPORTS_IF_NONE_MATCH && existing) {
    const wanted = String(ifNoneMatch).trim();
    const current = etagFor(existing);
    const matched = wanted === '*' ||
      wanted.split(',').map((s) => s.trim()).some((s) => s === current);
    if (matched) {
      if (VERBOSE) console.log(`[dav] 412 If-None-Match ${wanted} already matches ${current}`);
      return send(res, 412, 'Precondition Failed');
    }
  }

  const data = await readBody(req);
  // With --strict-collections this server behaves like Apache mod_dav, which
  // is what Synology DSM runs: a PUT into a folder that does not exist is a
  // 409, not a quiet mkdir. Creating the folder behind the client's back hid
  // the one case that matters most — a brand new vault syncing to an empty
  // server — because every local test passed against a server that was more
  // forgiving than any real one.
  if (STRICT_COLLECTIONS) {
    let parent;
    try { parent = await fsp.stat(path.dirname(info.abs)); } catch { parent = null; }
    if (!parent || !parent.isDirectory()) {
      if (VERBOSE) console.log(`[dav] 409 PUT into a missing collection: ${info.rel}`);
      return send(res, 409, 'Conflict');
    }
  }
  await fsp.mkdir(path.dirname(info.abs), { recursive: true });
  await fsp.writeFile(info.abs, data);
  const stat = await fsp.stat(info.abs);
  send(res, existing ? 204 : 201, '', { ETag: etagFor(stat) });
}

async function handleDelete(req, res, info) {
  let stat;
  try { stat = await fsp.stat(info.abs); } catch { return send(res, 404, 'Not found'); }
  const ifMatch = req.headers['if-match'];
  if (ifMatch !== undefined && SUPPORTS_IF_MATCH) {
    const current = etagFor(stat);
    if (String(ifMatch).trim() !== '*' && String(ifMatch).trim() !== current) {
      if (VERBOSE) console.log(`[dav] 412 DELETE If-Match ${ifMatch} != ${current}`);
      return send(res, 412, 'Precondition Failed');
    }
  }
  await fsp.rm(info.abs, { recursive: true, force: true });
  send(res, 204, '');
}

async function handleMkcol(req, res, info) {
  try {
    const st = await fsp.stat(info.abs);
    if (st.isDirectory()) return send(res, 405, 'Collection already exists');
    return send(res, 405, 'A file already exists at that path');
  } catch { /* free */ }
  await fsp.mkdir(info.abs, { recursive: true });
  send(res, 201, '');
}

async function handleMove(req, res, p, info) {
  const destination = req.headers.destination;
  if (!destination) return send(res, 400, 'Missing Destination header');
  const origin = new URL(destination, `http://${req.headers.host}`);
  const dp = decodePath(origin.pathname);
  const dest = dp === null ? null : resolve(dp);
  if (!dest) return send(res, 400, 'Destination outside the DAV root');

  try { await fsp.stat(info.abs); } catch { return send(res, 404, 'Not found'); }

  const overwrite = String(req.headers.overwrite ?? 'T').toUpperCase() !== 'F';
  let destExists = false;
  try { destExists = !!(await fsp.stat(dest.abs)).isFile(); } catch { destExists = false; }

  // RFC 4918 §9.9.2: MOVE with Overwrite: F onto an existing destination is
  // a failed precondition, and the source must survive untouched. Renaming
  // anyway would silently destroy the note that was already at the target.
  if (destExists && !overwrite) {
    if (VERBOSE) console.log('[dav] 412 MOVE Overwrite:F onto an existing destination');
    return send(res, 412, 'Precondition Failed');
  }

  await fsp.mkdir(path.dirname(dest.abs), { recursive: true });
  await fsp.rename(info.abs, dest.abs);
  send(res, destExists ? 204 : 201, '');
}

// ----------------------------------------------------------------- server

const server = http.createServer(async (req, res) => {
  const started = Date.now();
  let status = 500;
  try {
    if (!authorized(req)) {
      status = 401;
      return send(res, 401, 'Unauthorized', {
        'WWW-Authenticate': `Basic realm="JotIt Test DAV", charset="UTF-8"`,
      });
    }

    const method = req.method.toUpperCase();
    if (method === 'OPTIONS') {
      status = 204;
      return send(res, 204, '', {
        DAV: '1, 2',
        Allow: 'OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE',
        'MS-Author-Via': 'DAV',
      });
    }

    const p = decodePath(req.url ?? '/');
    if (p === null) return send(res, 400, 'Bad request path');
    const info = resolve(p);
    if (info === null) return send(res, 403, 'Forbidden');

    switch (method) {
      case 'PROPFIND': status = 207; await handlePropfind(req, res, p, info); break;
      case 'GET': status = 200; await handleGet(req, res, info); break;
      case 'HEAD': status = 200; await handleGet(req, res, info); break;
      case 'PUT': {
        let exists = false;
        try { await fsp.stat(info.abs); exists = true; } catch { /* new */ }
        status = exists ? 204 : 201;
        await handlePut(req, res, p, info);
        break;
      }
      case 'DELETE': status = 204; await handleDelete(req, res, info); break;
      case 'MKCOL': status = 201; await handleMkcol(req, res, info); break;
      case 'MOVE': status = 204; await handleMove(req, res, p, info); break;
      default:
        status = 405;
        send(res, 405, 'Method not allowed', { Allow: 'OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE' });
    }
  } catch (err) {
    status = 500;
    send(res, 500, String(err?.stack ?? err));
  } finally {
    if (VERBOSE) {
      console.log(`[dav] ${req.method} ${req.url} -> ${status} (${Date.now() - started}ms)`);
    }
  }
});

server.listen(PORT, HOST, () => {
  // The port actually bound, not the one asked for: `--port 0` means "any
  // free port", and a caller that guessed the number would then be talking
  // to nothing. The endpoint is printed so the caller can read it back.
  const actual = server.address().port;
  console.log(`JotIt test WebDAV server`);
  console.log(`  root       ${ROOT}`);
  console.log(`  endpoint   http://${HOST}:${actual}${BASE}/`);
  console.log(`  auth       ${USER} / ${PASS}`);
  console.log(`  getctag    ${SUPPORTS_CTAG ? 'yes' : 'NO (Synology-like)'}`);
  console.log(`  If-Match   ${SUPPORTS_IF_MATCH ? 'yes (honoured)' : 'NO (nginx-dav-like)'}`);
});