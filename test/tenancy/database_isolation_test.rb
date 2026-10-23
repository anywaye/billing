require "test_helper"

# The account boundary as POSTGRES enforces it, proven against this database
# rather than through the models.
#
# ## Why this file is separate from `test/tenant/`
#
# `scope :for_account` is one layer and the policies are a second. Every test in
# `test/tenant/` passes on the first layer alone — it is green whether or not
# `anywaye.protect_table` was ever called, whether or not the policies are FORCED,
# and whether or not the role the service runs as is exempt from them. Those files
# are the application-level proof and this one does not replace them; what is
# green here is POSTGRES refusing, and nothing else can make it green. The
# statements below are RAW SQL on purpose: no model, no `for_account`, nothing
# between the statement and the policy.
#
# ## Why every statement runs under `set local role`
#
# The suite's connection is the environment's role, and locally that is the
# cluster's own superuser — which bypasses every policy. Measured against a
# protected table holding two rows:
#
#   $ psql -U kaka -c "select count(*) from probe_rows"                        -> 2
#   $ psql -U kaka -c "set role billing;     select count(*) from probe_rows"  -> 0
#   $ psql -U kaka -c "set role billing_app; select count(*) from probe_rows"  -> 0
#
# So an assertion made by the suite's own connection would read every account's
# rows whether or not a boundary exists. Every test below therefore acts as
# `billing` (the owner) or `billing_app` (the login role a request uses) — the two
# roles the policies name — and one test asserts those roles' own attributes, so a
# cluster provisioned differently fails BY NAME rather than with a green suite
# that proves the opposite of what it says.
#
# ## The shape of a denial, and why it is three shapes and not one
#
#   * a `using` clause that filters a row out      -> NOTHING AT ALL, zero rows
#   * a `with check` violation                     -> 42501
#   * a missing grant                              -> 42501
#
# The first is the one a naive assertion gets wrong: a policy that hides another
# account's row raises no error, so "this raises" passes when it suppresses
# nothing. Every read denial here is therefore a row COUNT. And because 42501 is
# also what a table nobody can write to raises, every write denial is paired with
# the same write under the row's OWN account, which has to succeed — otherwise the
# refusal is explained by a table with no grants rather than by a policy.
class DatabaseIsolationTest < ActionDispatch::IntegrationTest
  # The same two accounts `test/support/two_accounts.rb` uses, so the isolation
  # specs and the tenant specs are about the same pair rather than two pairs that
  # drifted.
  ACCOUNT_A = TwoAccounts::ACCOUNT_A
  ACCOUNT_B = TwoAccounts::ACCOUNT_B

  # Two more, holding nothing, for the write tests — and they are needed because of
  # a constraint rather than for tidiness. `customers` is unique on
  # `(owner_type, owner_id, processor)` and `processor` is CHECKed to `'stripe'`, so
  # an account can hold exactly ONE customer row: an insert naming an account whose
  # customer is already there is refused by that index (23505) before the policy is
  # asked anything, and the test would report a policy denial it never reached.
  FRESH_A = "55555555-5555-4555-8555-555555555555".freeze
  FRESH_B = "66666666-6666-4666-8666-666666666666".freeze

  OWNER_ROLE = TestSupport::DatabaseTenancy::OWNER_ROLE
  APP_ROLE = TestSupport::DatabaseTenancy::APP_ROLE

  # The four privileges a table's DML is made of, in the order Postgres sorts them.
  # Named once because two tests ask the same question about different table sets.
  DML = %w[DELETE INSERT SELECT UPDATE].freeze

  # Every table the boundary covers, and the number of policies each must carry.
  # `customers` has five: the four commands plus the webhook path's resolve
  # policy, which is `for select` and predicated on the value a caller presents
  # rather than on an account — see `db/tenancy/account_isolation.sql`.
  PROTECTED = { "subscriptions" => 4, "charges" => 4, "customers" => 5 }.freeze

  # The processor customer id `test/fixtures/stripe/invoice.paid.json` carries.
  # The webhook specs need the anywaye customer that answers to it, or the delivery
  # is recorded `unknown_customer` and no charge is written — which is a
  # legitimate outcome this file also asserts, one test below.
  INVOICE_CUSTOMER = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    # Every row this file asserts about, written through the same seam a request
    # uses: as the OWNER (which FORCE binds) with the row's own account as the
    # identity. A fixture written by the suite's own connection would bypass the
    # policies on the way in, and a boundary that cannot refuse a write is not
    # being tested by a row that was written past it.
    @customer_a = insert_customer(ACCOUNT_A, "cus_ISOLATIONaccountAAAAAAA")
    @customer_b = insert_customer(ACCOUNT_B, "cus_ISOLATIONaccountBBBBBBB")
    @plan = insert_plan
    # A second plan, so a write test's control insert cannot be refused by
    # `subscriptions_live_account_plan_idx` — an account holds at most one live
    # subscription per plan, and the fixtures above already took `@plan` for A.
    @plan_2 = insert_plan
    @subscription_a = insert_subscription(ACCOUNT_A, @customer_a, "sub_ISOLATIONaccountAAAAAAA")
    @subscription_b = insert_subscription(ACCOUNT_B, @customer_b, "sub_ISOLATIONaccountBBBBBBB")
    @charge_a = insert_charge(ACCOUNT_A, @customer_a, @subscription_a, "ch_ISOLATIONaccountAAAAAAA")
    @charge_b = insert_charge(ACCOUNT_B, @customer_b, @subscription_b, "ch_ISOLATIONaccountBBBBBBB")
  end

  # === the catalog, which is the decision rather than the behaviour ===========

  test "every protected table is enabled, FORCED, owned by billing, and carries its policies" do
    PROTECTED.each do |table, policies|
      enabled, forced, found, owner = table_boundary(table).map(&:to_s)

      assert_equal "1", enabled,
        "#{table}: row level security is not enabled, so no policy on it is ever evaluated"
      assert_equal "1", forced,
        "#{table}: row level security is not FORCED — Postgres exempts a table's OWNER unless it " \
        "is, so the role that owns this table reads every account's rows while the policies sit in " \
        "the catalog looking like a boundary"
      assert_equal policies.to_s, found,
        "#{table}: expected one policy per command (a later grant can only widen a command it names), " \
        "found #{found}"
      assert_equal OWNER_ROLE, owner,
        "#{table} is owned by #{owner}, not by #{OWNER_ROLE}. The owner arm of this file would then be " \
        "a different role from the one the boundary is about"
    end
  end

  test "every policy names the two roles, and every clause calls the identity wrapped" do
    PROTECTED.each_key do |table|
      rows(<<~SQL).each do |name, roles, clause|
        select policyname, roles::text, coalesce(qual, with_check)
        from pg_policies
        where schemaname = 'public' and tablename = #{quote(table)}
        order by policyname
      SQL
        assert_equal "{#{OWNER_ROLE},#{APP_ROLE}}", roles,
          "#{table}.#{name} is bound to #{roles}: a policy that names no role applies to PUBLIC, and a " \
          "policy bound to a superuser or a BYPASSRLS role is evaluated on no read at all"

        # The wrapping is the whole of the per-row rule: a bare call in a policy
        # qualifier is evaluated once per candidate row, the wrapped form is
        # hoisted into an InitPlan and runs once per statement. Measured on this
        # cluster, two rows, identity unset:
        #
        #   using (account_id = (select probe_id()))   ->  1 call
        #   using (account_id = probe_id())            ->  2 calls
        #
        # The two spellings below are the same predicate under two `search_path`s
        # — kit's `credential_tables()` records that a deparsed policy drops the
        # schema for a reader whose own schema is `anywaye`, so a check that
        # insisted on one spelling would pass or fail on who ran it.
        assert_match(/select\s+(anywaye\.)?(current_account_id|current_credential_digest)\(\)/i, clause,
          "#{table}.#{name} does not call its identity as `(select anywaye.…())`: #{clause}")
      end
    end
  end

  test "the two roles are what the boundary is made of, and the app role holds nothing but DML" do
    superuser, bypassrls, canlogin, = role_attributes(OWNER_ROLE).map(&:to_s)
    assert_equal "1", canlogin, "#{OWNER_ROLE} is not a LOGIN role"
    assert_equal "0", superuser,
      "#{OWNER_ROLE} is a SUPERUSER, so the policies do not bind it and nothing in this file is proven"
    assert_equal "0", bypassrls,
      "#{OWNER_ROLE} has BYPASSRLS, so the policies do not bind it and nothing in this file is proven"

    superuser, bypassrls, canlogin, = role_attributes(APP_ROLE).map(&:to_s)
    assert_equal "1", canlogin, "#{APP_ROLE} is not a LOGIN role"
    assert_equal "0", superuser, "#{APP_ROLE} is a SUPERUSER, so the policies do not bind it"
    assert_equal "0", bypassrls, "#{APP_ROLE} has BYPASSRLS, so the policies do not bind it"

    # The app role owns nothing, which is the whole of the second half: a role that
    # OWNED a policy's table could `alter table … disable row level security` or
    # `drop policy`, and no amount of FORCE stops it — FORCE is about the owner
    # being SUBJECT to its policies, not about the owner being unable to REMOVE
    # them.
    owned = ActiveRecord::Base.connection.select_values(<<~SQL)
      select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_roles r on r.oid = c.relowner
      where n.nspname = 'public' and c.relkind = 'r' and r.rolname = #{quote(APP_ROLE)}
    SQL
    assert_equal [], owned, "#{APP_ROLE} owns tables, so it can switch their policies off"

    # Membership of the weaker role by the stronger one is what lets a migration
    # and this suite act as the app role. The REVERSE membership would undo the
    # design: the role the service runs as would hold the owner's privileges and
    # could drop its own boundary.
    membership = count(<<~SQL)
      select count(*)
      from pg_auth_members m
      join pg_roles member on member.oid = m.member
      join pg_roles granted on granted.oid = m.roleid
      where member.rolname = #{quote(APP_ROLE)} and granted.rolname = #{quote(OWNER_ROLE)}
    SQL
    assert_equal 0, membership, "#{APP_ROLE} is a member of #{OWNER_ROLE}, so the login role holds ownership"

    # THE GRANTS ARRIVED, and this is the assertion the two-role split needs most:
    # Rails' `structure_dump` writes `--no-privileges`, so a test database built
    # from a dump (or from `schema.rb`, which cannot express a grant at all) has an
    # app role that is refused a PLAIN SELECT — with SQLSTATE 42501, the same code
    # a policy raises. A broken test database therefore looks exactly like a
    # working boundary, which is why the install path (`test/support/
    # database_boundary.rb`) runs `anywaye.protect_table`, and why this asserts the
    # result rather than trusting it.
    PROTECTED.each_key do |table|
      granted = ActiveRecord::Base.connection.select_values(<<~SQL)
        select privilege_type from information_schema.table_privileges
        where grantee = #{quote(APP_ROLE)} and table_schema = 'public' and table_name = #{quote(table)}
      SQL
      assert_equal %w[DELETE INSERT SELECT UPDATE], granted.sort,
        "#{APP_ROLE} holds #{granted.sort} on #{table}: this database was built without the grants, so " \
        "every assertion about the app role below would fail for a reason that has nothing to do with " \
        "the boundary"
    end
  end

  test "billing_app can reach every table the application queries, and the list is derived" do
    # THE GRANT HALF OF THE SPLIT, GENERALISED — and derived in BOTH directions, so a
    # table added next month without a grant fails here rather than in production:
    #
    #   * the tables this DATABASE holds, from the catalog: every base table in
    #     `public` except Rails' own bookkeeping, which no request reads (the `db:*`
    #     tasks do, and those run as the owner, on the migration credential);
    #   * the tables the APPLICATION names, from the models themselves — and from
    #     `app/models/`, not from `ActiveRecord::Base.descendants`, which after an
    #     eager load is every model the FRAMEWORK brings too (Active Storage,
    #     Action Mailbox/Text, Solid Queue/Cache/Cable). Those twenty tables are not
    #     in this database at all, and a derivation that counted them would be
    #     asking a question about Rails rather than about this service.
    #
    # The CONTROL is as load-bearing as the derivation: a list that came back empty
    # would make every assertion below pass over nothing, which is the shape
    # `TestSpans.rendered!` refuses for the same reason. `customers` is the control
    # table because the whole boundary is built on it.
    app_models = Dir[Rails.root.join("app/models/*.rb")].sort.filter_map do |path|
      klass = File.basename(path, ".rb").camelize.constantize
      klass if klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class?
    end
    models = app_models.map(&:table_name).uniq.sort

    catalog = rows(<<~SQL).flatten
      select table_name from information_schema.tables
      where table_schema = 'public' and table_type = 'BASE TABLE'
        and table_name not in ('schema_migrations', 'ar_internal_metadata')
      order by table_name
    SQL

    assert_includes models, "customers",
      "the derivation found no application models, so every assertion below would pass on an empty list"

    assert_empty models - catalog,
      "these models' tables are not in this database, so the derivation is not looking at the schema the " \
      "application runs against"

    missing = catalog.to_h { |table| [ table, DML - table_privileges(table) ] }.reject { |_, absent| absent.empty? }
    assert_empty missing,
      "#{APP_ROLE} cannot reach these tables, and the application queries all of them: " \
      "#{missing.map { |table, absent| "#{table} (missing #{absent.join(', ')})" }.join('; ')}"

    # And the control ON THE CHECKER: the privilege query above must be able to
    # answer "no" about a privilege the role does not hold. `TRUNCATE` is the one to
    # test it with because holding it would be a real defect and not just a
    # surprise: it empties a table for every account, so it is a way around a policy
    # that no `USING` clause can stop.
    truncatable = catalog.select { |table| table_privileges(table).include?("TRUNCATE") }
    assert_empty truncatable,
      "#{APP_ROLE} holds TRUNCATE on #{truncatable.join(', ')}: it is not DML, and it is a way around " \
      "row level security rather than a way through it"

    # AND THE TWO TABLES THE APPLICATION MUST NOT WRITE. `20261016190000_grant_app_role_runtime_dml.rb`
    # grants the app role its DML in bulk and revokes these two out of it, and the
    # reason is identity's: an application that can rewrite its own migration history
    # can make the next migrate re-run against live data. Asserted here as well as
    # there because the installer's path (`db/tenancy/app_role.sql`) does not grant
    # them either, and the claim is about the DATABASE rather than about which file
    # was last run against it. `SELECT` is deliberately not asserted against: a
    # development boot reads its own migration versions for the pending-migration
    # check, and reading a version list is not writing one.
    writable = %w[schema_migrations ar_internal_metadata].select do |table|
      (table_privileges(table) & %w[INSERT UPDATE DELETE]).any?
    end
    assert_empty writable,
      "#{APP_ROLE} can write #{writable.join(', ')}: an application that can rewrite its own migration " \
      "history can make the next migrate re-run against live data"
  end

  # === the read denials: another account's row, and no identity at all ========

  test "subscriptions: another account's row reads as zero rows, as the owner and as the app role" do
    as_owner_role { as_account(ACCOUNT_B) { assert_equal 1, subscriptions_of(ACCOUNT_B) } }

    as_owner_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from subscriptions where id = #{quote(@subscription_b)}"),
          "the OWNER counted another account's subscription, so FORCE is not binding it"
        assert_equal 1, subscriptions_of(ACCOUNT_A), "the owner cannot see its own account's subscription"
      end
    end

    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from subscriptions where id = #{quote(@subscription_b)}"),
          "#{APP_ROLE} counted another account's subscription"
        assert_equal 1, subscriptions_of(ACCOUNT_A), "#{APP_ROLE} cannot see its own account's subscription"
      end
    end
  end

  test "charges: another account's row reads as zero rows, as the owner and as the app role" do
    as_owner_role { as_account(ACCOUNT_B) { assert_equal 1, charges_of(ACCOUNT_B) } }

    as_owner_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from charges where id = #{quote(@charge_b)}"),
          "the OWNER counted another account's charge, so FORCE is not binding it"
        assert_equal 1, charges_of(ACCOUNT_A), "the owner cannot see its own account's charge"
      end
    end

    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from charges where id = #{quote(@charge_b)}"),
          "#{APP_ROLE} counted another account's charge"
        assert_equal 1, charges_of(ACCOUNT_A), "#{APP_ROLE} cannot see its own account's charge"
      end
    end
  end

  test "customers: another account's row reads as zero rows, as the owner and as the app role" do
    # This table is the one whose predicate is hand-written, because its tenancy key
    # is `owner_type` + `owner_id` rather than a column called `account_id`. So the
    # mismatch is here: a policy that matched `owner_id` alone would read a
    # `User`-owned row whose `owner_id` happens to be an account id, and one that
    # matched `owner_type` alone would read every account's rows.
    as_owner_role { as_account(ACCOUNT_B) { assert_equal 1, customers_of(ACCOUNT_B) } }

    as_owner_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from customers where id = #{quote(@customer_b)}"),
          "the OWNER counted another account's customer, so FORCE is not binding it"
        assert_equal 1, customers_of(ACCOUNT_A), "the owner cannot see its own account's customer"
      end
    end

    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal 0, count("select count(*) from customers where id = #{quote(@customer_b)}"),
          "#{APP_ROLE} counted another account's customer"
        assert_equal 1, customers_of(ACCOUNT_A), "#{APP_ROLE} cannot see its own account's customer"
      end
    end
  end

  test "customers: a User-owned row is in no account's listing, even when its owner_id is an account id" do
    # THE `owner_type` ARM OF THE READ PREDICATE, which the assertions above cannot
    # reach: they compare two rows that differ in `owner_id`, so a policy that had
    # lost `owner_type = 'Account'` and matched `owner_id` alone would pass every one
    # of them. This row is the fixture that separates the two arms — a `User`-owned
    # customer whose `owner_id` IS account B's uuid — and it is written as the
    # suite's own role rather than through the seam, because the `with check`
    # refuses to create it (asserted two tests below). Rows like it exist: the
    # application-level specs in `test/tenant/` and `test/models/outbox_event_test.rb`
    # create `User`-owned customers, and one of them uses an account id as the owner.
    execute(<<~SQL)
      insert into customers (owner_type, owner_id, processor, metadata, created_at, updated_at)
      values ('User', #{quote(ACCOUNT_B)}, 'stripe', '{}', now(), now())
    SQL

    as_owner_role do
      as_account(ACCOUNT_B) do
        assert_equal 0, count("select count(*) from customers where owner_type = 'User'"),
          "the OWNER read a User-owned customer as account B's: the read predicate matches `owner_id` alone"
      end
    end

    as_app_role do
      as_account(ACCOUNT_B) do
        assert_equal 0, count("select count(*) from customers where owner_type = 'User'"),
          "#{APP_ROLE} read a User-owned customer as account B's"
        assert_equal 1, customers_of(ACCOUNT_B),
          "account B cannot see its own customer, so the zero above is also explained by a policy hiding everything"
      end
    end
  end

  test "with no identity, every protected table reads zero rows for both roles" do
    # The state every request starts in, and the state a worker with no account is
    # in. `begin_account(nil)` CLEARS rather than failing — the substrate's own
    # convention — and an absent identity reads ZERO ROWS rather than raising,
    # because "no identity" and "an identity that owns none of these rows" must be
    # indistinguishable: a policy that raised would tell a caller their request was
    # not authenticated, and a caller can be made to believe that about somebody
    # else's request.
    without_identity do
      as_owner_role do
        PROTECTED.each_key do |table|
          assert_equal 0, count("select count(*) from #{table}"),
            "with no account set, the OWNER read #{table}"
        end
      end

      as_app_role do
        PROTECTED.each_key do |table|
          assert_equal 0, count("select count(*) from #{table}"),
            "with no account set, #{APP_ROLE} read #{table}"
        end
      end
    end
  end

  # === the write denials: 42501, and the same write that must succeed =========

  test "subscriptions: a write into another account is refused with 42501, and its own account can write" do
    as_app_role do
      as_account(ACCOUNT_A) do
        # `@plan_2`, which neither account is on: the only thing that can refuse this
        # row is the policy. On `@plan` it would be refused by
        # `subscriptions_live_account_plan_idx` as well (23505), and the test would
        # report a policy denial it never reached.
        assert_equal "42501", refusal(<<~SQL), "#{APP_ROLE} wrote a subscription into another account"
          insert into subscriptions (account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
          values (#{quote(ACCOUNT_B)}, #{quote(@customer_b)}, #{quote(@plan_2)}, 'sub_ISOLATIONcrossAccountAAA', 'active', now(), now())
        SQL

        # The same write under the row's OWN account. Without this half, the refusal
        # above is also explained by a table nobody can write to — and 42501 is the
        # code for both.
        execute(<<~SQL)
          insert into subscriptions (account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
          values (#{quote(ACCOUNT_A)}, #{quote(@customer_a)}, #{quote(@plan_2)}, 'sub_ISOLATIONownAccountAAAAA', 'active', now(), now())
        SQL
        assert_equal 2, subscriptions_of(ACCOUNT_A)
      end
    end
  end

  test "charges: a write into another account is refused with 42501, and its own account can write" do
    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal "42501", refusal(<<~SQL), "#{APP_ROLE} wrote a charge into another account"
          insert into charges (account_id, customer_id, subscription_id, processor_charge_id, amount, currency, description, paid_at, created_at, updated_at)
          values (#{quote(ACCOUNT_B)}, #{quote(@customer_b)}, #{quote(@subscription_b)}, 'ch_ISOLATIONcrossAccountAAA', 1900, 'USD', 'a charge in somebody else''s account', now(), now(), now())
        SQL

        execute(<<~SQL)
          insert into charges (account_id, customer_id, subscription_id, processor_charge_id, amount, currency, description, paid_at, created_at, updated_at)
          values (#{quote(ACCOUNT_A)}, #{quote(@customer_a)}, #{quote(@subscription_a)}, 'ch_ISOLATIONownAccountAAAAA', 1900, 'USD', 'a charge in its own account', now(), now(), now())
        SQL
        assert_equal 2, charges_of(ACCOUNT_A)
      end
    end
  end

  test "customers: a write into another account is refused with 42501, and its own account can write" do
    as_app_role do
      # Two accounts that hold no customer row, for the reason `FRESH_A`/`FRESH_B`
      # give: one customer per account, so the denial and the control each need an
      # account the unique index has not seen.
      as_account(FRESH_A) do
        assert_equal "42501", refusal(<<~SQL), "#{APP_ROLE} wrote a customer into another account"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
          values ('Account', #{quote(FRESH_B)}, 'stripe', 'cus_ISOLATIONcrossAccountAAA', '{}', now(), now())
        SQL

        execute(<<~SQL)
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
          values ('Account', #{quote(FRESH_A)}, 'stripe', 'cus_ISOLATIONownAccountAAAAA', '{}', now(), now())
        SQL
        assert_equal 1, customers_of(FRESH_A)
        assert_equal 0, customers_of(FRESH_B)
      end
    end
  end

  test "customers: a row written with owner_type other than Account is refused" do
    # The `with check` carries `owner_type = 'Account'` and not only the owner id,
    # and this is why. A row written as `User` with an `owner_id` equal to the
    # caller's account id would be invisible to every account (the `using` clause
    # requires `owner_type = 'Account'`) while holding the unique
    # `(owner_type, owner_id, processor)` key — a row nobody can read and everybody
    # can collide with.
    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal "42501", refusal(<<~SQL), "a User-owned customer was written with an account id as its owner"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
          values ('User', #{quote(ACCOUNT_A)}, 'stripe', 'cus_ISOLATIONuserOwnedAAAAA', '{}', now(), now())
        SQL
      end
    end
  end

  test "an update and a delete of another account's row match zero rows, and leave the row intact" do
    before = rows("select id, amount from charges where id = #{quote(@charge_b)}")
    assert_equal 1, before.size, "the fixture row is not there, so nothing below is being tested"

    as_app_role do
      as_account(ACCOUNT_A) do
        # `using`, so these are the denials that raise NOTHING: an update whose
        # predicate matches no row is a successful statement that changed nothing.
        execute("update charges set amount = 1 where id = #{quote(@charge_b)}")
        execute("delete from charges where id = #{quote(@charge_b)}")

        # The control: the same two statements under the row's own account change it.
        execute("update charges set amount = 2500 where id = #{quote(@charge_a)}")
        assert_equal "2500", ActiveRecord::Base.connection.select_value(
          "select amount from charges where id = #{quote(@charge_a)}"
        ).to_s
      end
    end

    # And the row is still there, unchanged — the half that separates "the statement
    # matched nothing" from "the statement was quietly dropped". Read back as the
    # SUITE's own role and not as the account that tried: a read of another account's
    # row is itself denied (zero rows), so a check made from inside that scope would
    # report "gone" for a row that is sitting right there.
    assert_equal before, rows("select id, amount from charges where id = #{quote(@charge_b)}"),
      "another account's charge moved or vanished under an update/delete that should have matched nothing"
  end

  test "the app role is refused every way of switching the boundary off" do
    # Not a catalog fact — the catalog says the app role owns nothing, and these are
    # the behaviours that fact is for. Each is a way the boundary could be removed
    # by the role the running service actually logs in as.
    {
      "disable row level security" => "alter table customers disable row level security",
      "drop a policy" => "drop policy customers_anywaye_select on customers",
      "truncate" => "truncate customers",
      "add a policy that widens" =>
        "create policy billing_app_opens_the_table on customers for select to billing_app using (true)"
    }.each do |what, statement|
      as_app_role do
        assert_equal "42501", refusal(statement), "#{APP_ROLE} was not refused: #{what}"
      end
    end
  end

  # === the sweep, and the control that makes its empty result mean something ===

  test "no account-scoped table is unprotected, with a planted one as the control" do
    connection = ActiveRecord::Base.connection

    # THE CONTROL. `unprotected_tables()` returning no rows is the same output as a
    # function that is broken, deleted, or looking at the wrong schema — so a table
    # with an `account_id` and no policies is planted first, and the sweep has to
    # NAME it, with the reason, before its verdict on the real schema counts. A
    # temporary table, because the sweep deliberately includes this session's
    # `pg_temp` and no other session can put a table in scope by creating one.
    connection.execute("create temp table anywaye_sweep_control (id bigserial primary key, account_id uuid)")

    reported = rows("select table_schema, table_name, why from anywaye.unprotected_tables()")
    control = reported.find { |_, name, _| name == "anywaye_sweep_control" }
    assert control,
      "the sweep did not report a planted unprotected account-scoped table, so an empty result from it " \
      "means nothing"
    assert_equal "row level security is not enabled", control[2]

    connection.execute("drop table anywaye_sweep_control")

    assert_equal [], rows("select table_schema, table_name, why from anywaye.unprotected_tables()"),
      "these tables carry an account_id and are not protected"
  end

  # === the properties the request path depends on ============================

  test "the identity dies with the transaction that set it" do
    # What `Tenancy.with_account` is built on, and the reason it opens a
    # transaction rather than setting a variable: `is_local => true` means the
    # identity goes when the transaction does. On a POOLED connection a
    # session-level value would go back to the pool still carrying tenant A's
    # identity, and the next request on that connection — tenant B's — would be
    # handed it.
    #
    # ON A CONNECTION OF ITS OWN, because the suite's connections are inside a
    # transaction for the whole of every test and the fact being asserted is about
    # what happens when a transaction ENDS. It is also the only way to see the
    # connection as a request opens one: with NO identity.
    with_a_connection_of_its_own do |connection|
      assert_nil connection.exec("select anywaye.current_account_id()").getvalue(0, 0),
        "a fresh connection already carries an identity, which it should not"

      connection.exec("begin")
      connection.exec("select anywaye.begin_account('#{ACCOUNT_A}')")
      assert_equal ACCOUNT_A, connection.exec("select anywaye.current_account_id()").getvalue(0, 0)
      connection.exec("commit")

      assert_nil connection.exec("select anywaye.current_account_id()").getvalue(0, 0),
        "the identity outlived the transaction that set it. On a pooled connection that is tenant A's " \
        "identity handed to tenant B, which is the leak all of this exists to prevent"
    end
  end

  test "a released savepoint carries the identity out, and a rolled-back one does not" do
    # THE TRAP, measured rather than assumed, and written down because it is a way
    # a test can be green while proving the opposite of what it says:
    #
    #   begin; savepoint s; set_config(..., is_local => true); release savepoint s
    #
    # leaves the identity set in the ENCLOSING transaction — only the outermost
    # COMMIT or ROLLBACK reverts it. A nested `transaction do` is a savepoint, so a
    # request driven from a spec sets the identity inside one and every LATER
    # assertion runs as that account unless the helper puts it back. `as_account`
    # in `test/support/tenancy.rb` is that putting-back, and this measurement is
    # why it exists.
    connection = ActiveRecord::Base.connection
    # A known starting identity: the suite sets no connection-wide account (nothing
    # in the request path does either — see `Tenancy`), so the fixtures above leave
    # it cleared and a comparison against "whatever it was" would compare nil with
    # nil.
    Tenancy.begin_account(ACCOUNT_A)

    connection.transaction(requires_new: true) do
      Tenancy.begin_account(ACCOUNT_B)
      raise ActiveRecord::Rollback
    end
    assert_equal ACCOUNT_A, database_identity,
      "ROLLBACK TO SAVEPOINT did not revert the identity, which is what contains a refused statement's " \
      "identity along with the statement"

    connection.transaction(requires_new: true) { Tenancy.begin_account(ACCOUNT_B) }
    assert_equal ACCOUNT_B, database_identity,
      "a released savepoint no longer carries the identity out. The helpers' restore is still correct, " \
      "but the substrate's transaction-locality claim now needs re-reading"

    Tenancy.begin_account(ACCOUNT_A)
  end

  # === the request's identity actually reaches Postgres ======================

  test "a /v1 read under the app role sees exactly the caller's account" do
    # THE READ HALF, as the role the application's pool logs in as. Nothing here
    # touches the database directly: this is a real request through the middleware
    # stack, the router and the controller, on a connection that is `billing_app` and
    # has no identity set — so the listing is what the policies answer for the
    # account the token names.
    without_identity do
      as_app_role do
        acts_as(ACCOUNT_A)
        get "/v1/customers"

        assert_response :ok
        ids = json_body.fetch("data").map { |row| row.fetch("id") }
        assert_equal [ @customer_a ], ids,
          "the listing is not exactly the caller's own customer"
        refute_includes ids, @customer_b,
          "another account's customer is in the listing, so the request's own identity is not reaching Postgres"
      end
    end
  end

  test "a /v1 write for account A succeeds under the app role, where the same write with no identity is refused" do
    # THE PROPERTY THE REQUEST BINDING EXISTS FOR, and the one nothing else in this
    # file can see: that `V1::BaseController#with_account_scope` puts the token's
    # claim into the database's identity before the action's first query.
    #
    # AS THE ROLE THE APPLICATION'S POOL LOGS IN AS — `billing_app`, the login role
    # that owns nothing — and with the connection's identity CLEARED, so the request's
    # own `begin_account` is the only thing that can make this write legal. It is the
    # posture the composed stack runs in (`docker-compose.yml`'s app URL) and the one
    # `bin/docker-entrypoint` no longer contradicts by migrating as the owner first.
    without_identity do
      as_app_role do
        # The control first: the row the request is about to write, written by raw
        # SQL with no identity, is refused.
        assert_equal "42501", refusal(<<~SQL), "a customer was written with no identity at all"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
          values ('Account', #{quote(ACCOUNT_A)}, 'stripe', 'cus_ISOLATIONnoIdentityAAAAA', '{}', now(), now())
        SQL

        # `FRESH_A`, which holds no customer yet: `POST /v1/customers` is a 409 for
        # an account that already has one on this processor, and a test that passed
        # on a 409 would prove nothing about the write.
        acts_as(FRESH_A)
        post "/v1/customers", params: { processor: "stripe", email: "isolation@example.com" }, as: :json
        assert_response :created
        assert_equal FRESH_A, json_body.dig("owner", "id")

        # And the row is really there, as the role that wrote it: one of account A's
        # own, written by a request whose identity came from the token.
        assert_equal 1, count(<<~SQL), "the request answered 201 and wrote nothing"
          select count(*) from customers where owner_id = #{quote(FRESH_A)} and email = 'isolation@example.com'
        SQL
      end
    end
  end

  test "a signed Stripe webhook resolves its own account, where the same row is invisible without one" do
    # The signature-authenticated surface has no token to take an account from, so
    # the account has to come out of the payload — through
    # `customers_anywaye_resolve` and `Webhooks::AccountResolution`. Under the owner
    # role with no identity, which is both the posture a webhook runs in and the role
    # a request logs in as today — the suite's own connection would bypass the
    # policies and hide a broken resolution behind a green test.
    #
    # `FRESH_A`, because the account can hold exactly one customer row (see the
    # constant) and this test needs the customer the invoice names to be its only one.
    insert_customer(FRESH_A, INVOICE_CUSTOMER)

    without_identity do
      as_app_role do
        # The resolution is the only thing that can see this row: with no identity
        # and no presented value, the customer the invoice names is invisible.
        assert_equal 0, count("select count(*) from customers where processor_customer_id = #{quote(INVOICE_CUSTOMER)}"),
          "the customer was readable with no identity, so the webhook below would pass without resolving anything"

        # And it is exactly ONE row when the value is presented — the mechanism
        # widens a read to the row a caller names, not to the table.
        Tenancy.begin_credential(INVOICE_CUSTOMER)
        assert_equal 1, count("select count(*) from customers"),
          "a resolution session can browse the customers table"
        assert_equal 0, count("select count(*) from customers where id = #{quote(@customer_b)}"),
          "a resolution session read a row whose value it did not present"
        Tenancy.begin_credential(nil)

        post_stripe_webhook(stripe_fixture("invoice.paid"))

        assert_response :ok
        assert_equal 1, count("select count(*) from charges where account_id = #{quote(FRESH_A)}"),
          "the delivery wrote no charge: the webhook path could not resolve the account the event belongs to"
      end
    end
  end

  test "a webhook naming no customer this service knows writes nothing and says so" do
    # The other half of the resolution: an event for a customer created in the
    # processor's dashboard resolves to NO account, and the honest outcome is a
    # recorded refusal rather than a row in whichever account the connection
    # happened to be carrying — the same answer the path gave before any of this
    # existed, which is what makes the resolution an addition rather than a change
    # of behaviour.
    #
    # A SUBSCRIPTION event, because that is the path where the refusal is recorded:
    # `Subscriptions::Refused` becomes `Webhooks::Ignored` and the delivery carries
    # `ignored:unknown_customer`. The invoice path is silent by design — the charge
    # recorder skips a payment it cannot attach to a customer and the event is still
    # emitted — which is the documented gap in `Webhooks::Charges::Recorder` and not
    # something this file can assert a refusal for.
    without_identity do
      as_app_role do
        post_stripe_webhook(stripe_fixture("customer.subscription.created"))

        assert_response :ok
        assert_equal 0, count("select count(*) from subscriptions"), "a subscription was written with no account"
        assert_equal 1, count("select count(*) from processor_webhooks where processed_at is not null")
        assert_match(/unknown_customer/, ActiveRecord::Base.connection.select_value(
          "select error from processor_webhooks limit 1"
        ).to_s, "the delivery was not recorded as the refusal it is")
      end
    end
  end

  private

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end

  def execute(sql)
    ActiveRecord::Base.connection.execute(sql)
  end

  # The three counters, so every assertion above reads as the question it is about
  # rather than as a SQL string.
  def subscriptions_of(account_id)
    count("select count(*) from subscriptions where account_id = #{quote(account_id)}")
  end

  def charges_of(account_id)
    count("select count(*) from charges where account_id = #{quote(account_id)}")
  end

  # The privileges `role` holds on `table`, asked of Postgres rather than read out
  # of `information_schema.table_privileges` — `has_table_privilege` answers for
  # inherited and PUBLIC-granted privileges too, so a grant that arrived by a route
  # this file does not write is still counted.
  def table_privileges(table, role = APP_ROLE)
    %w[SELECT INSERT UPDATE DELETE TRUNCATE].select do |privilege|
      ActiveRecord::Base.connection.select_value(
        "select has_table_privilege(#{quote(role)}, #{quote("public.#{table}")}, #{quote(privilege)})"
      )
    end
  end

  def customers_of(account_id)
    count("select count(*) from customers where owner_type = 'Account' and owner_id = #{quote(account_id)}")
  end

  # A connection this process did not have before, opened the way a request's
  # would be — same database, same role, no session-level identity. The settings
  # are read from the pool's own configuration and never printed: this database's
  # credential is not this suite's to write down.
  def with_a_connection_of_its_own
    settings = ActiveRecord::Base.connection_db_config.configuration_hash
    connection = PG.connect(
      host: settings[:host],
      port: settings[:port],
      dbname: settings[:database],
      user: settings[:username],
      password: settings[:password]
    )
    yield connection
  ensure
    connection&.close
  end

  # --- fixtures, written through the seam a request uses ---------------------

  # Every row below is written as the OWNER role with the row's own account as the
  # identity, so the INSERT policy checks it on the way in. `insert_customer` for
  # account B therefore proves that a write for B is legal when B is the identity —
  # the same fact the write denials above are paired with.

  def insert_customer(account_id, processor_customer_id)
    id = SecureRandom.uuid
    as_owner_role do
      as_account(account_id) do
        execute(<<~SQL)
          insert into customers (id, owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
          values (#{quote(id)}, 'Account', #{quote(account_id)}, 'stripe', #{quote(processor_customer_id)}, '{}', now(), now())
        SQL
      end
    end
    id
  end

  # `plans` is the platform catalogue and is deliberately NOT account-scoped, so
  # this one row is written with no identity at all — which is itself the assertion
  # that the catalogue was left alone. The price id is unique per call because
  # `plans_processor_price_id_idx` is unique and this file needs two plans (see
  # `@plan_2`).
  def insert_plan
    id = SecureRandom.uuid
    execute(<<~SQL)
      insert into plans (id, name, slug, processor_price_id, amount_cents, currency, interval, trial_days, active, entitlements, created_at, updated_at)
      values (#{quote(id)}, 'Isolation plan', 'isolation-#{SecureRandom.hex(4)}', 'price_ISOLATION#{SecureRandom.hex(6)}', 1900, 'USD', 'month', 0, true, '{}', now(), now())
    SQL
    id
  end

  def insert_subscription(account_id, customer_id, processor_subscription_id)
    id = SecureRandom.uuid
    as_owner_role do
      as_account(account_id) do
        execute(<<~SQL)
          insert into subscriptions (id, account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
          values (#{quote(id)}, #{quote(account_id)}, #{quote(customer_id)}, #{quote(@plan)}, #{quote(processor_subscription_id)}, 'active', now(), now())
        SQL
      end
    end
    id
  end

  def insert_charge(account_id, customer_id, subscription_id, processor_charge_id)
    id = SecureRandom.uuid
    as_owner_role do
      as_account(account_id) do
        execute(<<~SQL)
          insert into charges (id, account_id, customer_id, subscription_id, processor_charge_id, amount, currency, description, paid_at, created_at, updated_at)
          values (#{quote(id)}, #{quote(account_id)}, #{quote(customer_id)}, #{quote(subscription_id)}, #{quote(processor_charge_id)}, 1900, 'USD', 'isolation fixture', now(), now(), now())
        SQL
      end
    end
    id
  end
end
