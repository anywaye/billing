# The account boundary as POSTGRES sees it, for the specs that assert it.
#
# ## The two layers, kept apart on purpose
#
# `Current`-less: billing has no `Current` object; the claim lives in
# `current_principal` on the request path, and the database identity lives in a
# transaction-local GUC. The two are different things and the isolation specs move
# the second one, because the boundary they assert is the database's:
#
#   `current_account_id` (the token's claim)  what `for_account` reads, so it is
#                                             what makes a query carry its
#                                             `where` clause. Proven by
#                                             `test/tenant/**`.
#   `cafaye.begin_account` (the GUC)          what the POLICIES read. Proven here.
#
# ## Why every helper runs under an explicit role
#
# The suite's connection is the environment's — locally the cluster's own role,
# which is a superuser, and in CI the `postgres` superuser. A superuser bypasses
# every policy, so an assertion made by that connection proves nothing at all:
# it reads every account's rows whether or not a policy exists. Measured, on this
# cluster, against a protected table with two rows in it:
#
#   $ psql -U kaka   -c "select count(*) from probe_rows"                      -> 2
#   $ psql -U kaka   -c "set role billing;     select count(*) from probe_rows" -> 0
#   $ psql -U kaka   -c "set role billing_app; select count(*) from probe_rows" -> 0
#
# So `as_owner_role` and `as_app_role` are not conveniences: they are the only way
# any statement in `test/tenancy/` is answered by a role the policies bind. `set
# local role` rather than `set role`, because the suite is inside its own
# transaction for the whole of every test and the switch has to die with it —
# measured, and it does:
#
#   begin; set local role billing_app; select current_user;  -> billing_app
#   rollback; select current_user;                           -> kaka
#
# The isolation suite asserts the roles' own attributes (not superuser, not
# BYPASSRLS, owning nothing) so that a cluster provisioned differently fails by
# name rather than by a green suite that proves the opposite of what it says.
module TestSupport
  # Named `DatabaseTenancy` rather than `Tenancy` so that the app's own
  # `Tenancy` module is reachable without a leading `::` — a module named
  # `Tenancy` inside `TestSupport` shadows it, and the first version of this file
  # failed every test with `undefined method 'begin_account' for module
  # TestSupport::DatabaseTenancy`, which names the shadow rather than the mistake.
  module DatabaseTenancy
    OWNER_ROLE = "billing".freeze
    APP_ROLE = "billing_app".freeze

    # Run the block as another account IN THE DATABASE, and put the identity back
    # afterwards.
    #
    # THE PUTTING-BACK IS MEASURED, NOT TIDINESS. `cafaye.begin_account/1` is
    # `set_config(..., is_local => true)`, and in Postgres a GUC set inside a
    # SAVEPOINT that is RELEASED — which is what a nested `transaction do` is —
    # SURVIVES into the enclosing transaction; only the outermost COMMIT or
    # ROLLBACK reverts it. Measured on this cluster:
    #
    #   begin; select cafaye.begin_account('…A…');
    #   savepoint s; select cafaye.begin_account('…B…');
    #   release savepoint s; select cafaye.current_account_id();  -> …B…   <-- the trap
    #   commit;             select cafaye.current_account_id();   -> NULL
    #
    # A request driven from a spec sets the identity inside its own transaction,
    # which is nested inside the test's — so without this restore, every assertion
    # AFTER that request would run as the account the request acted as, which is
    # the one way a green test can prove the opposite of what it says.
    #
    # A nil argument CLEARS the identity, which is the substrate's own convention
    # and not a special case written here.
    def as_account(account_id)
      previous = database_identity
      ::Tenancy.begin_account(account_id)
      yield
    ensure
      # `presence` because a cleared identity is the empty STRING in the GUC, and
      # `begin_account(nil)` is what clears it.
      #
      # AND IT TOLERATES AN ABORTED TRANSACTION, which is not defensiveness: a test
      # that asserts a refusal and then lets an unrelated error unwind would
      # otherwise have THIS statement — `current transaction is aborted`, 25P02 —
      # replace the error that caused it, and the failure would name the helper
      # instead of the bug. Nothing needs restoring in that case: an aborted
      # transaction is one about to be rolled back, and the rollback reverts the
      # GUC along with everything else.
      begin
        ::Tenancy.begin_account(previous.presence)
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

    # The state a worker with no account is in, and the state every statement in
    # this suite starts in when it is not asserting something else.
    def without_identity(&block)
      as_account(nil, &block)
    end

    # The identity Postgres is holding, read back from the connection rather than
    # remembered in Ruby — the two are different layers and only one of them is
    # what a policy reads.
    def database_identity
      ActiveRecord::Base.connection.select_value("select cafaye.current_account_id()")
    end

    # Act as the role that owns the tables. It is the arm no catalog proves:
    # `pg_class.relforcerowsecurity` says the policies bind the owner, and only
    # running a denial as the owner says so.
    def as_owner_role(&block)
      as_role(OWNER_ROLE, &block)
    end

    # Act as the login role the service runs as. It owns nothing, so it cannot
    # switch the boundary off.
    def as_app_role(&block)
      as_role(APP_ROLE, &block)
    end

    def as_role(role)
      connection = ActiveRecord::Base.connection
      connection.execute("set local role #{role}")
      yield connection
    ensure
      # An aborted transaction has already lost the role, and a second failure
      # here would replace the assertion that caused it with 25P02.
      begin
        connection.execute("reset role")
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

    # Run a statement expected to be REFUSED, and answer with its SQLSTATE.
    #
    # The savepoint is not ceremony: a refusal in Postgres ABORTS the transaction
    # it happened in, and every later statement in that transaction fails with
    # 25P02 until it is rolled back — so without containing it, the first denial
    # asserted would take the rest of the test with it. `requires_new: true` is a
    # SAVEPOINT, and it rolls back to it and re-raises.
    #
    # The CODE is asserted rather than the message, because 42501 is the code a
    # POLICY raises AND the code a MISSING GRANT raises: an assertion on the code
    # alone cannot tell a working boundary from a table nobody can write to, which
    # is why every write denial here is paired with the same write under the row's
    # own account.
    def refusal(sql)
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.connection.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(sql)
        end
      end

      error.cause.result.error_field(PG::PG_DIAG_SQLSTATE)
    end

    def row(sql)
      ActiveRecord::Base.connection.select_rows(sql).first
    end

    def rows(sql)
      ActiveRecord::Base.connection.select_rows(sql)
    end

    def count(sql)
      ActiveRecord::Base.connection.select_value(sql).to_i
    end

    # What the catalog says about one table, as integers because Postgres answers
    # a boolean as 't'/'f' over the wire and `assert_not "f"` PASSES: a
    # non-empty string is truthy, and an assertion that is green on exactly the
    # value it is meant to catch is worse than no assertion at all.
    def table_boundary(table)
      ActiveRecord::Base.connection.select_rows(<<~SQL).first
        select c.relrowsecurity::int,
               c.relforcerowsecurity::int,
               (select count(*) from pg_policy p where p.polrelid = c.oid)::int,
               pg_get_userbyid(c.relowner)
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = #{ActiveRecord::Base.connection.quote(table)}
      SQL
    end

    def policy_names(table)
      ActiveRecord::Base.connection.select_values(<<~SQL)
        select p.polname
        from pg_policy p
        join pg_class c on c.oid = p.polrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = #{ActiveRecord::Base.connection.quote(table)}
        order by p.polname
      SQL
    end

    def role_attributes(role)
      row(<<~SQL)
        select rolsuper::int, rolbypassrls::int, rolcanlogin::int, rolcreatedb::int
        from pg_roles where rolname = #{ActiveRecord::Base.connection.quote(role)}
      SQL
    end
  end
end

module ActiveSupport
  class TestCase
    include TestSupport::DatabaseTenancy
  end
end
