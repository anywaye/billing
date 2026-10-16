# The grants `billing_app` needs to be billing's application, and nothing more.
#
# ## WHY THIS FILE EXISTS
#
# The substrate runs this service's migrations as the database OWNER (a
# migration is DDL; `billing_app` owns nothing) and the service itself
# connects as `billing_app` — the role in the `DATABASE_URL` the box writes
# into `billing-secrets`. An owner is exempt from its own row-level-security
# policies, so a billing running as the owner has no account boundary at all;
# the app role is the one the policies bind, which is the entire reason the
# split exists. What the split also means is that a table created by a
# migration belongs to `billing` and grants `billing_app` **nothing**, and
# the measured result of connecting without this file is the refusal every
# service in this fleet has written down once:
#
#     ERROR:  permission denied for table plans
#
# The other services' history has the same file under their own names —
# identity's `00019_app_role_dml.sql` and courier's
# `20261005120000_grant_app_role_runtime_dml.exs` — and this is billing's.
#
# ## WHY IT IS A MIGRATION
#
# Privileges the application depends on are schema, and schema belongs in the
# ordered, reversible, deployed-with-the-code history. A GRANT in a compose
# file is applied by nothing on the box; a GRANT in kit's init script is a
# change to another repository and a race with this one's tables.
#
# ## WHY `ALL TABLES` IS RIGHT HERE WHEN IDENTITY REFUSED IT
#
# identity named its tables one by one to keep `goose_db_version` (its
# migrator's bookkeeping) out of the app role's reach — an app that can
# DELETE its own migration history can make the next migrate re-run against
# live data. The danger is the same here, so the two Rails bookkeeping tables
# are REVOKED after the blanket grant: `schema_migrations` and
# `ar_internal_metadata` stay owner-only. Everything else is granted in
# bulk because everything else is what the app reads and writes, and
# `ALTER DEFAULT PRIVILEGES` covers the tables later migrations add, which a
# named list cannot. The sequence grant rides along: Rails' `id` columns are
# identity sequences, and INSERT fails without USAGE on them.
class GrantAppRoleRuntimeDml < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO billing_app;
      GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO billing_app;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO billing_app;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO billing_app;
      REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE schema_migrations, ar_internal_metadata FROM billing_app;
    SQL
  end

  def down
    execute <<~SQL
      REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM billing_app;
      REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public FROM billing_app;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public
        REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM billing_app;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public
        REVOKE USAGE, SELECT ON SEQUENCES FROM billing_app;
    SQL
  end
end
