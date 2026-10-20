# Installing the account boundary into a database, from the DDL the migration runs.
#
# ## Why this is not only a migration
#
# The migration installs the boundary into a database that already exists. But
# Rails has a second way to build a database — `db:schema:load`, which `db:prepare`
# runs on a database that does not exist yet — and `db/schema.rb` cannot express a
# policy, a row level security bit, a function or a grant. So a database built that
# way has the three tables and NONE of the boundary, and `db:migrate` never runs
# to fix it: the schema load marks every migration applied. A fresh production
# database would therefore come up unprotected, silently, with the application's
# own scoping as its only defence — which is exactly the state this whole change
# exists to leave behind.
#
# `lib/tasks/tenancy_substrate.rake` enhances `db:schema:load` and `db:prepare`
# with this, and the test suite calls it at boot for the database Rails builds for
# the suite (a third path, `maintain_test_schema!`, which calls
# `DatabaseTasks.load_schema` directly and so reaches neither rake task).
#
# ## As which role, and why it matters
#
# `cafaye.protect_table` binds every policy it writes to `current_user` and
# `current_user || '_app'`, so the role that INSTALLS the boundary is the role the
# boundary is about. This installs it as `billing`:
#
#   * in production the migration and `db:prepare` already run as `billing`, and
#     everything below is a no-op;
#   * in a test database — created by whatever role the suite connects as — the
#     three protected tables are RE-OWNED to `billing` first, because a policy's
#     ENABLE, FORCE and grants all require ownership. Without that the "owner" in
#     the test database would be the suite's own connection role, which is a
#     superuser on this machine and in CI, and a superuser is never bound by row
#     level security — so every owner-arm assertion would pass for the reason that
#     makes it worthless.
#
# Re-owning is skipped when the tables are already `billing`'s, so a production
# run does not touch ownership.
#
# ## What it proves while it is there
#
# `cafaye.unprotected_tables()` has to be empty when the install finishes, and a
# non-empty answer RAISES. The isolation suite asserts the same thing again with a
# planted unprotected table as the control, because an empty result from a broken
# sweep looks exactly like a clean database.
module Tenancy
  module Substrate
    # The tables the boundary covers, in the order the DDL protects them. Named
    # here as well as in the migration so a table added to one and not the other is
    # visible in both places; the sweep below is what actually fails.
    PROTECTED = %w[subscriptions charges customers].freeze

    # The two roles. `billing` owns the tables and ran the migration; `billing_app`
    # owns nothing and holds DML only, so the role a request logs in as cannot
    # alter a table's policies off.
    OWNER_ROLE = "billing".freeze
    APP_ROLE = "billing_app".freeze

    module_function

    def install!(connection = ActiveRecord::Base.connection)
      require_roles!(connection)
      prepare_ownership!(connection)

      connection.transaction do
        # `set local role`, so the role switch dies with this transaction and the
        # connection is left as it was — a session-level `set role` here would
        # change what every later statement on this pooled connection runs as.
        connection.execute("set local role #{OWNER_ROLE}")
        connection.execute(read("substrate.sql"))
        connection.execute(read("account_isolation.sql"))
        # And the app role's door: the DML grants that let the role the application
        # logs in as reach the tables at all — including the four the account
        # boundary deliberately does not cover. A policy says which rows a role may
        # see; a grant is what lets it through the door, and a missing one is
        # refused with the same 42501 a policy raises. See `db/tenancy/app_role.sql`.
        connection.execute(read("app_role.sql"))

        unprotected = connection.select_rows("select table_schema, table_name, why from cafaye.unprotected_tables()")
        next if unprotected.empty?

        raise "these account-scoped tables are not protected: " \
              "#{unprotected.map { |schema, table, why| "#{schema}.#{table} (#{why})" }.join('; ')}"
      end
    end

    # The two roles, or a refusal that names the fix. `rolcanlogin` is checked as
    # well as existence because `protect_table` refuses a role that cannot log in —
    # and a NOLOGIN role with the right name would otherwise be discovered three
    # statements later, inside a plpgsql function, as `role "…" does not exist`.
    def require_roles!(connection)
      missing = [ OWNER_ROLE, APP_ROLE ].reject do |role|
        connection.select_value(<<~SQL)
          select 1 from pg_roles where rolname = #{connection.quote(role)} and rolcanlogin
        SQL
      end
      return if missing.empty?

      raise <<~MESSAGE
        the account boundary needs the LOGIN roles #{missing.join(' and ')}, and this cluster does not have #{missing.size == 1 ? 'it' : 'them'}.

        Every policy on subscriptions, charges and customers names them: #{OWNER_ROLE}
        owns the tables, #{APP_ROLE} owns nothing and holds DML only. They come from
        kit's cluster init script on a compose cluster (`KIT_POSTGRES_DATABASES=billing`)
        and from these statements on a host cluster:

          psql -d postgres -c "create role #{OWNER_ROLE} login nosuperuser nocreatedb nocreaterole noreplication"
          psql -d postgres -c "create role #{APP_ROLE} login nosuperuser nocreatedb nocreaterole noreplication"
          psql -d postgres -c "grant #{APP_ROLE} to #{OWNER_ROLE}"
      MESSAGE
    end

    # Everything `billing` needs before the DDL can be run AS `billing`, and every
    # step is a no-op when it is already true.
    #
    # THE WHOLE SCHEMA BECOMES `billing`'s, not only the three protected tables, and
    # the reason is a measurement rather than tidiness. In production every table in
    # this database is `billing`'s, because `billing` ran the migrations that created
    # them. A test database is built by whatever role the suite connects as, so a
    # request driven there as `billing` meets tables it does not own:
    #
    #   ERROR:  permission denied for table outbox_events
    #   ERROR:  permission denied for table processor_webhooks
    #
    # — both from requests the isolation suite drives as `billing`, and neither is
    # the boundary doing anything: they are a test database that does not look like
    # the one the service runs against. Re-owning makes it look like it, and it is
    # what makes the owner arm of the boundary meaningful for a role that owns the
    # tables and is not a superuser.
    #
    # Two grants come with it, and each was a measured failure:
    #
    #   * `create` on the public schema, because `alter … owner to` requires the NEW
    #     owner to hold CREATE on the schema. On PostgreSQL 15 and up PUBLIC keeps
    #     USAGE there and no longer has CREATE. A database owned by the service role
    #     gets it through `pg_database_owner`; a test database, created by whatever
    #     role the suite connects as, does not.
    #   * `create` on the DATABASE, because the substrate's first statement is
    #     `create schema if not exists cafaye`. Without it the install dies with
    #     `permission denied for database <name>` — measured — which names the object
    #     and not the missing grant.
    #
    # And the `cafaye` schema: when it exists and is not already `billing`'s, it is
    # DROPPED and rebuilt, rather than re-owned. Measured, and the measurement is why
    # this is a drop rather than an `alter schema … owner to`:
    #
    #   ERROR:  must be owner of function current_account_id
    #
    # Re-owning a schema does not re-own the functions inside it, and the substrate's
    # `create or replace function` needs ownership of the function it replaces.
    # Dropping the schema takes its functions and — by the dependency Postgres
    # records between a policy and the function its qualifier calls — the policies
    # with it, and the DDL immediately rebuilds both in the same transaction, so the
    # window in which the boundary does not exist is not observable.
    def prepare_ownership!(connection)
      connection.execute("grant usage, create on schema public to #{OWNER_ROLE}")
      connection.execute(<<~SQL)
        grant connect, create on database #{connection.quote_table_name(connection.select_value('select current_database()'))} to #{OWNER_ROLE}
      SQL

      connection.select_rows(<<~SQL).each do |kind, name|
        select case c.relkind when 'S' then 'sequence' else 'table' end, c.relname
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'p', 'S')
          and pg_get_userbyid(c.relowner) <> #{connection.quote(OWNER_ROLE)}
          and not (c.relkind = 'S' and exists (
            select 1 from pg_depend d
            where d.objid = c.oid and d.deptype = 'a'))
      SQL
        connection.execute("alter #{kind} public.#{connection.quote_table_name(name)} owner to #{OWNER_ROLE}")
      end

      cafaye_owner = connection.select_value("select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'cafaye'")
      foreign_functions = connection.select_value(<<~SQL).to_i
        select count(*)
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'cafaye' and pg_get_userbyid(p.proowner) <> #{connection.quote(OWNER_ROLE)}
      SQL
      return if cafaye_owner.nil? || (cafaye_owner == OWNER_ROLE && foreign_functions.zero?)

      connection.execute("drop schema cafaye cascade")
    end

    # kit's tenancy substrate and billing's own half of the boundary, from the files
    # the migration reads — one copy of the DDL, three callers. `Rails.root` rather
    # than `__dir__`, so a worktree and the main checkout resolve the same files.
    def read(name)
      path = Rails.root.join("db/tenancy", name)
      raise "the tenancy DDL is missing from #{path}" unless path.exist?

      path.read
    end
  end
end
