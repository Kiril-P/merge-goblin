-- Merge Goblin telemetry: one row per event. Nothing here can name a repo, PR, person
-- or line of code; the worker refuses anything that does not fit the fields below.
CREATE TABLE IF NOT EXISTS events (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  at       INTEGER NOT NULL,          -- server time, epoch seconds
  install  TEXT    NOT NULL,          -- random id made on the Mac; not derived from anything
  event    TEXT    NOT NULL,          -- review | daily | ui
  version  TEXT    NOT NULL DEFAULT '',
  os       TEXT    NOT NULL DEFAULT '',
  arch     TEXT    NOT NULL DEFAULT '',
  data     TEXT    NOT NULL DEFAULT '{}'  -- the rest, as validated JSON
);
CREATE INDEX IF NOT EXISTS events_at ON events(at);
CREATE INDEX IF NOT EXISTS events_event_at ON events(event, at);
CREATE INDEX IF NOT EXISTS events_install ON events(install, at);
