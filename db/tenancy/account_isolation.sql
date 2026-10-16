-- billing's account boundary, as Postgres enforces it.
--
-- WHO RUNS THIS, and why it is a file rather than a migration body. Two callers,
-- one copy of the DDL:
--
--   1. `db/migrate/20261016120000_account_isolation.rb` — production and
--      development, as the role that owns the tables (`billing` in production,
--      from `DATABASE_URL`).
--   2. `test/support/database_boundary.rb` — the test database. Rails builds that
--      one from `db/schema.rb`, which cannot express a policy, a function or a
--      grant, so without this second caller the isolation suite would assert
--      against a database with no boundary at all and every test in it would pass
--      or fail for a reason that has nothing to do with the boundary.
--
-- A third reader is `cafaye/core/harness/bin/tenancy-check`, which reads `.sql`
-- DDL and cannot read a Ruby migration. `billing/tenancy.yml` declares
-- `databaseEnforced: true` and names these policies; the checker can only hold
-- that declaration against the tree because the DDL is in a file it can read.
-- A change here therefore reaches an EXISTING database only through a new
-- migration — the file is read by the migration, it is not watched by it.
--
-- THE TWO TABLES THAT SPELL THE KEY `account_id`. `cafaye.protect_table` writes
-- everything they need: ENABLE, FORCE, one policy per command (select, insert,
-- update, delete), the `account_id` index, the REVOKE from PUBLIC and the DML
-- grant to the login role. Nothing here repeats any of it.
--
-- THE THIRD TABLE, `customers`, CANNOT USE IT, and the refusal is measured rather
-- than assumed. Its tenancy key is `owner_type` + `owner_id`, not `account_id`:
--
--     $ psql -U billing -d … -c "select cafaye.protect_table('probe_no_account')"
--     ERROR:  cafaye.protect_table(probe_no_account, billing_app): the table has no
--             account_id column, so there is nothing to scope it by.
--     HINT:   Either the column is spelled something else — write the policy
--             yourself and name the fleet's key — or this table is not
--             account-scoped and should not be protected.
--
-- So its policies are written here, with the predicate `Customer.for_account`
-- uses — `where(owner_type: "Account", owner_id: account_id)` — spelled the way
-- the table spells it. That mismatch between the column name and the key is the
-- one place in this file a mistake is possible, which is why the isolation suite
-- has more cases for this table than for the other two.
--
-- `owner_type = 'Account'` IS IN THE `with check` AND NOT ONLY IN THE `using`, and
-- it is the half that is easy to leave out. A `with check` that carried only
-- `owner_id = current_account_id()` would accept a row written with
-- `owner_type = 'User'` and `owner_id` = the caller's account id: a row the read
-- policies then hide from every account — including the one that wrote it —
-- while it holds the unique `(owner_type, owner_id, processor)` key against a
-- row that is not a customer of that account at all. `owner_type = 'Account'` in
-- the check is what makes "account-owned" and "readable by its account" the same
-- set.
--
-- THE FIFTH POLICY ON `customers` IS THE ONE EXEMPTION IN THIS FILE, and it is
-- the webhook path's. Read this paragraph before widening it.
--
-- `POST /v1/webhooks/stripe` is authenticated by signature, not by a token, and
-- it has no account identity to hand `cafaye.begin_account/1`: it knows a
-- processor's `cus_…` id and, on the checkout path, the cafaye customer uuid our
-- own session put in the subscription's metadata. The account is WHAT THE
-- RESOLUTION QUERY IS FOR — `Lifecycle#customer` and `Charges::Recorder` both
-- read a customer row and learn `owner_id` from it — so a query with no identity
-- cannot be scoped by an identity it has not computed yet. That is kit's MD24
-- case, and the substrate's answer to it is a resolve policy plus
-- `cafaye.begin_credential/1`: the caller presents a value it already holds, and
-- the policy widens the read to exactly the row whose column equals that value.
--
-- The predicate is in the POLICY and not only in the caller's query, which is the
-- whole design: RLS policies combine permissively, so a policy that said merely
-- "a resolution session may select this table" would hand the webhook path a
-- table-wide SELECT. Because the policy carries the same predicate the lookup
-- carries, the honest semantics are: a resolution session may read exactly the
-- customer whose id — or whose processor customer id — it presented, and nothing
-- else in this table.
--
-- What it cannot do, so nobody has to find out:
--   * it cannot write. `for select`, so every write policy still demands an
--     account identity and a resolution session cannot mint or move a customer.
--   * it does not open another table. `subscriptions`, `charges` and `plans` are
--     untouched by it.
--   * it cannot tell a secret from a label. The value has to be one a caller
--     cannot guess; both of the values the webhook presents are minted by us or
--     by the processor and are not enumerable. The `id` half is compared as
--     `id::text` because `uuid = text` is not an operator — measured:
--
--       $ select count(*) from probe_rows where account_id = probe_text();
--       ERROR:  operator does not exist: uuid = text
--
--     which means an uppercase or non-canonical uuid resolves nothing rather
--     than erroring: the safe direction, and the same direction as an absent
--     identity.
--   * it is NOT audited at runtime. `cafaye.credential_tables()` lists it (the
--     policy's name ends `_cafaye_resolve` and its qualifier calls
--     `cafaye.current_credential_digest()`), with `(unresolved)` in the column
--     because the qualifier names two of the table's own columns — an audit
--     finding an operator can read, not a silent widening.
--
-- Every clause below is written `(select cafaye.…())`, wrapped, and that is not
-- style: Postgres evaluates a bare function call in a policy qualifier once per
-- candidate row and hoists the wrapped form into an InitPlan that runs once per
-- statement. Measured on this cluster, two rows, identity unset:
--
--   using (account_id = (select probe_id()))   ->  1 call
--   using (account_id = probe_id())            ->  2 calls
--
-- so the wrapped spelling is the one a table that grows stays cheap on.

-- --- customers: the four account policies, hand-written ----------------------
--
-- `drop policy if exists` before each `create policy`, so this file is
-- re-runnable: the test database's installer (`test/support/database_boundary.rb`)
-- executes it on every suite boot, and a second `create policy` with the same name
-- is an error rather than a no-op. `cafaye.protect_table` does the same thing for
-- the two tables below, and for the same reason — a re-run converges instead of
-- failing, and a policy whose definition was corrected here cannot survive one.

alter table customers enable row level security;
alter table customers force row level security;

drop policy if exists customers_cafaye_select on customers;
drop policy if exists customers_cafaye_insert on customers;
drop policy if exists customers_cafaye_update on customers;
drop policy if exists customers_cafaye_delete on customers;
drop policy if exists customers_cafaye_resolve on customers;

create policy customers_cafaye_select on customers for select to billing, billing_app using (owner_type = 'Account' and owner_id = (select cafaye.current_account_id()));
create policy customers_cafaye_insert on customers for insert to billing, billing_app with check (owner_type = 'Account' and owner_id = (select cafaye.current_account_id()));
create policy customers_cafaye_update on customers for update to billing, billing_app using (owner_type = 'Account' and owner_id = (select cafaye.current_account_id())) with check (owner_type = 'Account' and owner_id = (select cafaye.current_account_id()));
create policy customers_cafaye_delete on customers for delete to billing, billing_app using (owner_type = 'Account' and owner_id = (select cafaye.current_account_id()));

-- --- customers: the webhook path's resolve policy ----------------------------

create policy customers_cafaye_resolve on customers for select to billing, billing_app using (id::text = (select cafaye.current_credential_digest()) or processor_customer_id = (select cafaye.current_credential_digest()));

-- The REVOKE belongs with the policies — `protect_table` does the same thing, right
-- after ENABLE and before its own `grant`s, so that "who can read this table" is
-- not "whoever the last migration remembered". The GRANTS to `billing_app` are
-- deliberately NOT here: every grant the app role holds lives in
-- `db/tenancy/app_role.sql`, so "what can the running process reach" has one answer
-- in one file — including the four tables the account boundary does not cover,
-- which need grants too because a grant is what lets a role through the door at
-- all. A missing one is refused with SQLSTATE 42501, the SAME code a policy raises,
-- and the isolation suite asserts them rather than inferring them from a green
-- denial: the suite is what found the omission when these four lines were the only
-- ones that existed.
revoke all on table customers from public;

-- No `owner_id` index, unlike the two tables below. `protect_table` creates one
-- because a policy is a filter on every candidate row, and this table already has
-- `index_customers_on_owner_type_and_owner_id_and_processor` — a unique index whose
-- first two columns are exactly the predicate's, so the policy's filter is served
-- by an index this table was built with.

-- --- subscriptions and charges: the key is a column, so the substrate writes it

-- The login role is named rather than derived, and the difference is measured.
-- `protect_table`'s default is `current_user || '_app'`, which is right wherever
-- the migration runs as the service's own role — production, where `DATABASE_URL`
-- is `billing`. It is wrong in the one environment that runs migrations as
-- something else: CI's `db:prepare` runs as the `postgres` superuser, so the
-- derived role is `postgres_app`, which does not exist, and `protect_table`
-- REFUSES the whole migration with `postgres_app is not a LOGIN role on this
-- cluster`. Naming `billing_app` keeps the migration runnable in every
-- environment and keeps the half that matters — the login role the policies bind
-- — the same everywhere; the owner side stays `current_user`, which is `billing`
-- wherever the boundary is real.

select cafaye.protect_table('subscriptions', 'billing_app');
select cafaye.protect_table('charges', 'billing_app');
