/// Schema definition and migration steps.
///
/// Migrations are addressed by `PRAGMA user_version` (ADR-10) rather than by
/// sqflite's own version counter, so the version lives in the database header
/// where any SQLite client can read it and a user who opens the vault with an
/// older build still migrates forward exactly once.
library;

import 'package:sqflite_common/sqlite_api.dart';

const int kSchemaVersion = 3;

/// One step from version [from] to `from + 1`.
typedef Migration = void Function(DatabaseExecutor db);

final Map<int, Migration> _migrations = {
  0: _v0ToV1,
  1: _v1ToV2,
  2: _v2ToV3,
};

/// Ordered list of migrations to apply when the database is at [from].
List<Migration> migrationsFrom(int from) {
  final out = <Migration>[];
  for (var v = from; v < kSchemaVersion; v++) {
    final step = _migrations[v];
    if (step == null) {
      throw StateError('no migration registered from schema version $v');
    }
    out.add(step);
  }
  return out;
}

void _v0ToV1(DatabaseExecutor db) {
  // ---- notes ------------------------------------------------------------
  // The file is the truth (ADR-1); this table is a rebuildable index. Every
  // boolean is NOT NULL with a CHECK so a nullable flag can never create a row
  // that `WHERE is_deleted = 0` silently skips — one of the v2.0 P1 bugs.
  db.execute('''
CREATE TABLE notes (
  id             TEXT    PRIMARY KEY,                 -- front-matter uid (ADR-2)
  path           TEXT    NOT NULL UNIQUE,             -- vault-relative, POSIX
  title          TEXT    NOT NULL DEFAULT '',
  body           TEXT    NOT NULL DEFAULT '',          -- derived cache
  content_hash   TEXT,                                 -- SHA-256 of file bytes
  file_size      INTEGER NOT NULL DEFAULT 0,
  file_mtime_ms  INTEGER,
  updated_at     INTEGER NOT NULL DEFAULT 0,          -- epoch ms, local edit
  synced_at      INTEGER,
  is_deleted     INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
  deleted_at     INTEGER
)''');
  db.execute('CREATE INDEX idx_notes_deleted ON notes(is_deleted)');
  db.execute('CREATE INDEX idx_notes_updated ON notes(updated_at DESC)');
  db.execute('CREATE INDEX idx_notes_syncedat ON notes(synced_at)');

  // ---- links ------------------------------------------------------------
  // target_note_id is nullable on purpose: a link to a note that does not
  // exist yet is a real link, not a broken row.
  db.execute('''
CREATE TABLE links (
  id              INTEGER PRIMARY KEY,
  source_note_id  TEXT    NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  target_note_id  TEXT             REFERENCES notes(id) ON DELETE SET NULL,
  target_path     TEXT,
  raw_target      TEXT    NOT NULL,
  link_type       TEXT    NOT NULL CHECK (link_type IN ('wiki', 'embed', 'markdown')),
  is_external     INTEGER NOT NULL DEFAULT 0 CHECK (is_external IN (0, 1)),
  UNIQUE (source_note_id, raw_target, link_type)
)''');
  db.execute('CREATE INDEX idx_links_source ON links(source_note_id)');
  db.execute('CREATE INDEX idx_links_target ON links(target_note_id)');
  db.execute('CREATE INDEX idx_links_target_path ON links(target_path)');
  // The graph view only ever asks for "what points here and is still dangling".
  db.execute('''
CREATE INDEX idx_links_dangling ON links(target_path)
  WHERE target_note_id IS NULL AND is_external = 0''');

  db.execute('''
CREATE TABLE link_aliases (
  source_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  alias          TEXT NOT NULL,
  target_note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  PRIMARY KEY (source_note_id, alias)
)''');

  // ---- tags -------------------------------------------------------------
  db.execute('CREATE TABLE tags (name TEXT PRIMARY KEY, display_name TEXT NOT NULL)');
  db.execute('''
CREATE TABLE note_tags (
  note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag     TEXT NOT NULL,
  PRIMARY KEY (note_id, tag)
)''');
  db.execute('CREATE INDEX idx_note_tags_tag ON note_tags(tag)');

  // ---- attachments ------------------------------------------------------
  // Attachments are immutable (ADR-11), so the row is created once and the
  // path is never rewritten.
  db.execute('''
CREATE TABLE attachments (
  id           TEXT    PRIMARY KEY,
  note_id      TEXT             REFERENCES notes(id) ON DELETE CASCADE,
  path         TEXT    NOT NULL UNIQUE,
  filename     TEXT    NOT NULL,
  mime         TEXT,
  size         INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT,
  created_at   INTEGER NOT NULL DEFAULT 0
)''');
  db.execute('CREATE INDEX idx_attachments_note ON attachments(note_id)');

  // ---- sync -------------------------------------------------------------
  db.execute('''
CREATE TABLE sync_roots (
  id               TEXT    PRIMARY KEY,
  name             TEXT    NOT NULL,
  base_url         TEXT    NOT NULL,
  collection_ctag  TEXT,                               -- collection level (set level)
  username         TEXT,
  credential_blob  TEXT,
  capabilities     TEXT    NOT NULL DEFAULT '{}',     -- JSON, ADR-8 negotiation
  enabled          INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  last_sync_at     INTEGER,
  -- Backoff lives here rather than in memory so a restart cannot reset it.
  -- §5.2 makes `next_attempt_at` the thing that makes `delay = 30s x 2^n`
  -- survive a crash; without this column a process that dies mid-backoff
  -- comes back and hammers a server that is already refusing it.
  next_attempt_at  INTEGER NOT NULL DEFAULT 0,
  last_error       TEXT,
  created_at       INTEGER NOT NULL DEFAULT 0
)''');

  db.execute('''
CREATE TABLE sync_meta (
  sync_root_id      TEXT NOT NULL REFERENCES sync_roots(id) ON DELETE CASCADE,
  path              TEXT NOT NULL,
  uid               TEXT,
  base_etag         TEXT,
  base_content_hash TEXT,
  base_path         TEXT,
  last_synced_at    INTEGER,                          -- §7.3 shows this as "conflict time"
  conflict_state    TEXT NOT NULL DEFAULT 'none'
      CHECK (conflict_state IN ('none','local_wins','remote_wins','conflict','pending_resolution')),
  conflict_copy_dir TEXT,
  PRIMARY KEY (sync_root_id, path)
)''');
  // Renames are found by identity, not by path, so uid is indexed per root.
  db.execute('CREATE INDEX idx_sync_meta_uid ON sync_meta(sync_root_id, uid)');
  db.execute('CREATE INDEX idx_sync_meta_conflict ON sync_meta(sync_root_id, conflict_state)');

  db.execute('''
CREATE TABLE pending_ops (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  sync_root_id    TEXT    NOT NULL REFERENCES sync_roots(id) ON DELETE CASCADE,
  op_type         TEXT    NOT NULL
      CHECK (op_type IN ('create','update','delete','rename','conflict_resolve')),
  target_path     TEXT    NOT NULL,
  prev_path       TEXT,
  payload         TEXT,
  payload_version INTEGER NOT NULL DEFAULT 1,
  state           TEXT    NOT NULL DEFAULT 'pending'
      CHECK (state IN ('pending','in_flight','done','dead')),
  last_error      TEXT,
  retry_count     INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL DEFAULT 0,
  updated_at      INTEGER NOT NULL DEFAULT 0
)''');
  db.execute('''
CREATE INDEX idx_pending_ops_ready ON pending_ops(sync_root_id, state, next_attempt_at)
''');
  // Every one of the five coalescing rules in §5.4 looks a queue up by target
  // path before deciding whether to merge, fold or append. Without this index
  // every enqueue is a full table scan of a table that grows by one row per
  // offline edit.
  db.execute('''
CREATE INDEX idx_pending_ops_target ON pending_ops(sync_root_id, target_path, state)
''');

  // ---- full-text search (ADR-3) ----------------------------------------
  // Self-contained FTS5 table plus three triggers. v2.0 declared an external
  // content table pointing at a `content` column that never existed, which is
  // why its search was broken at three separate levels.
  db.execute('''
CREATE VIRTUAL TABLE notes_fts USING fts5(
  uid UNINDEXED,
  path UNINDEXED,
  title,
  body,
  tokenize = 'trigram'
)''');

  db.execute('''
CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
  INSERT INTO notes_fts(rowid, uid, path, title, body)
  VALUES (new.rowid, new.id, new.path, new.title, new.body);
END''');
  db.execute('''
CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
  DELETE FROM notes_fts WHERE rowid = old.rowid;
END''');
  db.execute('''
CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
  DELETE FROM notes_fts WHERE rowid = old.rowid;
  INSERT INTO notes_fts(rowid, uid, path, title, body)
  VALUES (new.rowid, new.id, new.path, new.title, new.body);
END''');
}

void _v1ToV2(DatabaseExecutor db) {
  // ---- app lock (v3.0 §8.3) ---------------------------------------------
  // The whole point of this table is that the lockout survives a restart.
  // A backoff kept in memory resets the moment the process dies, which is
  // exactly what a person brute-forcing a PIN wants: kill, retry, repeat.
  //
  // One row, enforced by a CHECK rather than by convention.
  db.execute('''
CREATE TABLE app_lock (
  id              INTEGER PRIMARY KEY CHECK (id = 1),
  pin_hash        TEXT    NOT NULL,                    -- PBKDF2-HMAC-SHA256, hex
  salt            TEXT    NOT NULL,                    -- 16 random bytes, hex
  iterations      INTEGER NOT NULL,
  failed_attempts INTEGER NOT NULL DEFAULT 0,
  locked_until    INTEGER NOT NULL DEFAULT 0,          -- epoch ms
  biometric_on    INTEGER NOT NULL DEFAULT 0 CHECK (biometric_on IN (0, 1)),
  updated_at      INTEGER NOT NULL DEFAULT 0
)''');
}

void _v2ToV3(DatabaseExecutor db) {
  // ---- precondition failures (v3.0 §5.3 row 10) --------------------------
  // A 412 is not an error the next round heals on its own. If the base stays
  // stale and nothing counts the refusals, the same path can 412 on every pass
  // forever with nothing on screen but an empty "skipped" list. The counter is
  // per path and per root because that is the granularity at which the server
  // rejects: the precondition is `If-Match: <this path's base_etag>`.
  db.execute('ALTER TABLE sync_meta ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0');
  db.execute('ALTER TABLE sync_meta ADD COLUMN last_error TEXT');
}
