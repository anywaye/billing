-- The outbox table. This file is the contract, and it is core's:
-- cafaye/core: docs/event-outbox.md, the `create table` block in "The table".
--
-- It is shipped here rather than only described in a README because two callers
-- need the same bytes: a service that copies it into its own migration, and this
-- gem's own suite, which has to run against a real PostgreSQL because the whole
-- point of the outbox is what a transaction does when it rolls back. A test that
-- asserted the behaviour against a fake would be asserting the fake.
--
-- A service owns the table in its own repository and its own migration, and this
-- file is what it copies. It is deliberately a plain `.sql` file rather than a
-- Rails generator template, because the table is not a Rails concept — courier
-- and identity do not have a migration system at all — and because a service
-- that wants a different column list should be able to diff this file and say
-- why in its own commit.
--
-- The CHECK constraints are not in core's block. They are here because the
-- alternative is a malformed envelope reaching every consumer on the platform
-- and failing there, which is the worst place for a format error to surface.
-- They are the patterns from core's event-envelope.schema.json, copied.

create table if not exists outbox_events (
  id           uuid        primary key,
  event_type   text        not null,
  source       text        not null,
  subject      text        not null,
  time         timestamptz not null,
  data         jsonb       not null,
  created_at   timestamptz not null default now(),
  published_at timestamptz null,
  attempts     int         not null default 0,

  -- core's eventType pattern, verbatim from the schema. The first segment is a
  -- cafaye service name and is kebab-case, so it may contain a dash and never
  -- an underscore; the entity and action segments are snake_case.
  constraint outbox_events_event_type_format
    check (event_type ~ '^[a-z][a-z0-9]*(-[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*$'),

  -- core's serviceName pattern. A service name never contains a dot, so this
  -- also catches a `source` that is actually a full event type.
  constraint outbox_events_source_format
    check (source ~ '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'),

  -- core's subject pattern and its 1..200 length bound, in one constraint.
  -- `platform` is the reserved value for an event with no single entity, and it
  -- matches the pattern like any other identifier, which is the point: a
  -- required field with a reserved value is a value a consumer can always read.
  constraint outbox_events_subject_format
    check (subject ~ '^[A-Za-z0-9][A-Za-z0-9._:@/-]*$' and length(subject) between 1 and 200),

  -- The envelope's three-segment type names its own publisher. A row whose
  -- `source` is not the first segment of its `type` is a row two consumers
  -- would route differently, and nothing downstream would notice until one of
  -- them was wrong.
  constraint outbox_events_source_matches_type
    check (split_part(event_type, '.', 1) = source),

  -- `data` is `jsonb` so it is parsed, and a `jsonb` column that is null is a
  -- payload nobody can read. `jsonb` rather than `json` also normalises key
  -- order, so two identical payloads are byte-identical.
  constraint outbox_events_data_is_an_object
    check (jsonb_typeof(data) = 'object'),

  -- `attempts` counts publish attempts and is the input to backoff. A negative
  -- attempt count would make the backoff schedule undefined.
  constraint outbox_events_attempts_not_negative
    check (attempts >= 0)
);

-- The publisher's only query. Without this it is a sequential scan of every
-- event the service has ever published, forever. Partial, because published
-- rows are spent: indexing them would grow this index with every event the
-- service has ever published, to serve a query that filters them all out.
create index if not exists outbox_events_unpublished_idx
  on outbox_events (created_at, id)
  where published_at is null;

-- Per-entity ordering is the one ordering core guarantees, so this is the one
-- index the guarantee needs behind it.
create index if not exists outbox_events_subject_created_at_idx
  on outbox_events (subject, created_at);
