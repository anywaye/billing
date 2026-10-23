-- The app role's door: what `billing_app` may reach.
--
-- WHY A FILE ABOUT GRANTS SITS IN THE BOUNDARY'S DIRECTORY. Row level security is
-- half of the two-role split and GRANTS are the other half, and the two are
-- independent facts. A policy says WHICH ROWS a role may see once it is through
-- the door; a grant is what lets it through at all. A database can have every
-- policy in place and a role that is refused a plain `select` — with SQLSTATE
-- **42501**, the same code a policy raises — so a missing grant looks exactly like
-- a working boundary from the outside. `test/tenancy/database_isolation_test.rb`
-- asserts the grants arrived rather than inferring them from a green denial.
--
-- WHERE THIS FILE SITS BESIDE THE MIGRATION, because production already has one.
-- `db/migrate/20261016190000_grant_app_role_runtime_dml.rb` (landed while this
-- change was in flight) grants the app role its runtime DML in bulk, with
-- `ALTER DEFAULT PRIVILEGES` for tables later migrations add. That is the
-- PRODUCTION path, and it is the right one there: a migration is DDL, it runs
-- everywhere the schema is built by migrating, and it is ordered with the tables.
-- This file is the path the migration cannot take, and the list a reader can
-- check:
--
--   * `db:schema:load` builds a database WITHOUT running a migration — that is
--     how the test database is built, how a fresh one is built, and how
--     `db:prepare` builds a database that does not exist yet — and `schema.rb`
--     cannot express a grant any more than it can express a policy. The installer
--     (`lib/tenancy/substrate.rb`) runs this file for those databases, and
--     `lib/tasks/tenancy_substrate.rake` is what makes `db:prepare` reach it.
--   * the grants are the half of the split a reader has to be able to CHECK
--     against what the application queries, and the derivation
--     `test/tenancy/database_isolation_test.rb` runs needs a list to be the
--     claim about. A blanket grant is correct and is not a list.
--
-- The two paths overlap and neither is redundant: on a database that ran the
-- migration, every statement here is a no-op.
--
-- WHY THE FOUR TABLES THE BOUNDARY DOES NOT COVER ARE HERE. `plans`,
-- `processor_webhooks`, `idempotency_keys` and `outbox_events` are deliberately
-- NOT account-scoped — `tenancy.yml` gives the reasons at length (the catalogue is
-- what an account may buy and not what it owns; the outbox is drained across every
-- account by one publisher; a webhook receipt is addressed by the processor's
-- event id) — and that is a statement about POLICIES, not about grants. The
-- application still reads and writes all four, so the role it logs in as still
-- needs DML on them. **An unprotected table is exactly as unreachable as a
-- protected one to a role nobody granted anything to**, which is the mistake this
-- file exists to prevent. Measured, before these lines existed:
--
--   $ psql -U kaka -d billing_development -c \
--       "begin; set local role billing_app; select count(*) from processor_webhooks; rollback"
--   ERROR:  permission denied for table processor_webhooks
--
-- and the same for `plans`, `idempotency_keys` and `outbox_events`, each of which
-- the request path reaches: `POST /v1/plans` writes the catalogue, every delivery
-- writes a receipt and reads the catalogue, `IdempotentRequests` writes a claim,
-- and every write on the money path publishes an event.
--
-- WHAT IS DELIBERATELY NOT HERE, so the list is closed rather than merely short:
--
--   * `subscriptions` and `charges` need no grant from this file —
--     `anywaye.protect_table` writes theirs, in
--     `db/tenancy/account_isolation.sql`, and the isolation suite asserts all four
--     privileges on both.
--   * `customers` needs one and gets it below, because `protect_table` refuses a
--     table with no `account_id` column and therefore wrote no grant for it.
--   * nothing gets `TRUNCATE`, `REFERENCES` or `TRIGGER`. `TRUNCATE` is not DML
--     and it is a way around a policy (it empties the table for every account), so
--     the app role must not hold it — the isolation suite asserts the refusal.
--   * nothing gets DDL. That is the whole point of the split: `billing_app` owns
--     nothing, so it cannot `ALTER TABLE … DISABLE ROW LEVEL SECURITY`, cannot
--     `DROP POLICY`, and cannot `DROP TABLE`. The suite asserts the first two.
--
-- SCHEMA USAGE is in this file rather than beside each table because it is one
-- fact: without USAGE on `public` the role cannot resolve a table name at all, and
-- without USAGE on `anywaye` it cannot call `anywaye.begin_account/1` — which is the
-- first thing every request does, so its absence is a 42501 on every request that
-- reads as a permission bug rather than as the missing grant it is.
grant usage on schema public to billing_app;
grant usage on schema anywaye to billing_app;

-- --- customers: the grant `protect_table` could not write ---------------------

grant select, insert, update, delete on table customers to billing_app;
grant select, insert, update, delete on table ask_tokens_wallets, ask_tokens_transactions to billing_app;

-- --- the four tables the account boundary does not cover ----------------------

grant select, insert, update, delete on table plans to billing_app;
grant select, insert, update, delete on table processor_webhooks to billing_app;
grant select, insert, update, delete on table idempotency_keys to billing_app;
grant select, insert, update, delete on table outbox_events to billing_app;

-- --- sequences, and the measurement that says there are none -----------------
--
-- Measured on this cluster, on the development database and on a freshly built
-- test database: `select relname from pg_class where relkind = 'S' and
-- relnamespace = 'public'::regnamespace` returns **nothing**. Every id in this
-- schema is `uuid default gen_random_uuid()`, so there is no sequence for the role
-- to be refused — and a `GRANT` list that stops at tables is therefore correct
-- today.
--
-- THE LOOP IS HERE ANYWAY, and it is the one place this file is wider than the
-- measurement. A `bigserial` column added next month is a table the app role can
-- `select` and cannot `insert`, with the same 42501 and the same "looks like a
-- boundary" shape — kit's substrate carries the identical loop for the identical
-- reason (`protect_table`, and the note that the `identity` case only *happened*
-- to work through an undocumented executor path). The cost is one catalog query
-- per install.
--
-- It grants `USAGE` and nothing else: `USAGE` is what `nextval` checks, and it is
-- deliberately not `select` (which would let the role read `last_value` and reason
-- about how many rows other tables hold) and not `update` (which would let it
-- `setval` and forge ids). Scoped to the `public` schema, which in a
-- database-per-service cluster holds this service's tables and no other service's.
do $$
declare seq_name text;
begin
  for seq_name in
    select format('%I.%I', n.nspname, s.relname)
      from pg_class s
      join pg_namespace n on n.oid = s.relnamespace
     where s.relkind = 'S' and n.nspname = 'public'
  loop
    execute format('grant usage on sequence %s to billing_app', seq_name);
  end loop;
end $$;
