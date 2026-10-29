require "test_helper"

class DatabaseIsolationTest < ActionDispatch::IntegrationTest
  ACCOUNT_A = TwoAccounts::ACCOUNT_A
  ACCOUNT_B = TwoAccounts::ACCOUNT_B

  FRESH_A = "55555555-5555-4555-8555-555555555555".freeze
  FRESH_B = "66666666-6666-4666-8666-666666666666".freeze

  OWNER_ROLE = TestSupport::DatabaseTenancy::OWNER_ROLE
  APP_ROLE = TestSupport::DatabaseTenancy::APP_ROLE

  DML = %w[DELETE INSERT SELECT UPDATE].freeze

  PROTECTED = { "subscriptions" => 4, "charges" => 4, "customers" => 5 }.freeze

  INVOICE_CUSTOMER = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze

  setup do
    @customer_a = insert_customer(ACCOUNT_A, "cus_ISOLATIONaccountAAAAAAA")
    @customer_b = insert_customer(ACCOUNT_B, "cus_ISOLATIONaccountBBBBBBB")
    @plan = insert_plan
    @plan_2 = insert_plan
    @subscription_a = insert_subscription(ACCOUNT_A, @customer_a, "sub_ISOLATIONaccountAAAAAAA")
    @subscription_b = insert_subscription(ACCOUNT_B, @customer_b, "sub_ISOLATIONaccountBBBBBBB")
    @charge_a = insert_charge(ACCOUNT_A, @customer_a, @subscription_a, "ch_ISOLATIONaccountAAAAAAA")
    @charge_b = insert_charge(ACCOUNT_B, @customer_b, @subscription_b, "ch_ISOLATIONaccountBBBBBBB")
  end


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
        order by policyname
      SQL
        assert_equal "{#{OWNER_ROLE},#{APP_ROLE}}", roles,
          "#{table}.#{name} is bound to #{roles}: a policy that names no role applies to PUBLIC, and a " \
          "policy bound to a superuser or a BYPASSRLS role is evaluated on no read at all"

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

    owned = ActiveRecord::Base.connection.select_values(<<~SQL)
      select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_roles r on r.oid = c.relowner
    SQL
    assert_equal [], owned, "#{APP_ROLE} owns tables, so it can switch their policies off"

    membership = count(<<~SQL)
      select count(*)
      from pg_auth_members m
      join pg_roles member on member.oid = m.member
      join pg_roles granted on granted.oid = m.roleid
    SQL
    assert_equal 0, membership, "#{APP_ROLE} is a member of #{OWNER_ROLE}, so the login role holds ownership"

    PROTECTED.each_key do |table|
      granted = ActiveRecord::Base.connection.select_values(<<~SQL)
        select privilege_type from information_schema.table_privileges
      SQL
      assert_equal %w[DELETE INSERT SELECT UPDATE], granted.sort,
        "#{APP_ROLE} holds #{granted.sort} on #{table}: this database was built without the grants, so " \
        "every assertion about the app role below would fail for a reason that has nothing to do with " \
        "the boundary"
    end
  end

  test "billing_app can reach every table the application queries, and the list is derived" do
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

    truncatable = catalog.select { |table| table_privileges(table).include?("TRUNCATE") }
    assert_empty truncatable,
      "#{APP_ROLE} holds TRUNCATE on #{truncatable.join(', ')}: it is not DML, and it is a way around " \
      "row level security rather than a way through it"

    writable = %w[schema_migrations ar_internal_metadata].select do |table|
      (table_privileges(table) & %w[INSERT UPDATE DELETE]).any?
    end
    assert_empty writable,
      "#{APP_ROLE} can write #{writable.join(', ')}: an application that can rewrite its own migration " \
      "history can make the next migrate re-run against live data"
  end


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
    execute(<<~SQL)
      insert into customers (owner_type, owner_id, processor, metadata, created_at, updated_at)
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


  test "subscriptions: a write into another account is refused with 42501, and its own account can write" do
    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal "42501", refusal(<<~SQL), "#{APP_ROLE} wrote a subscription into another account"
          insert into subscriptions (account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
        SQL

        execute(<<~SQL)
          insert into subscriptions (account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
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
        SQL

        execute(<<~SQL)
          insert into charges (account_id, customer_id, subscription_id, processor_charge_id, amount, currency, description, paid_at, created_at, updated_at)
        SQL
        assert_equal 2, charges_of(ACCOUNT_A)
      end
    end
  end

  test "customers: a write into another account is refused with 42501, and its own account can write" do
    as_app_role do
      as_account(FRESH_A) do
        assert_equal "42501", refusal(<<~SQL), "#{APP_ROLE} wrote a customer into another account"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
        SQL

        execute(<<~SQL)
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
        SQL
        assert_equal 1, customers_of(FRESH_A)
        assert_equal 0, customers_of(FRESH_B)
      end
    end
  end

  test "customers: a row written with owner_type other than Account is refused" do
    as_app_role do
      as_account(ACCOUNT_A) do
        assert_equal "42501", refusal(<<~SQL), "a User-owned customer was written with an account id as its owner"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
        SQL
      end
    end
  end

  test "an update and a delete of another account's row match zero rows, and leave the row intact" do
    before = rows("select id, amount from charges where id = #{quote(@charge_b)}")
    assert_equal 1, before.size, "the fixture row is not there, so nothing below is being tested"

    as_app_role do
      as_account(ACCOUNT_A) do
        execute("update charges set amount = 1 where id = #{quote(@charge_b)}")
        execute("delete from charges where id = #{quote(@charge_b)}")

        execute("update charges set amount = 2500 where id = #{quote(@charge_a)}")
        assert_equal "2500", ActiveRecord::Base.connection.select_value(
          "select amount from charges where id = #{quote(@charge_a)}"
        ).to_s
      end
    end

    assert_equal before, rows("select id, amount from charges where id = #{quote(@charge_b)}"),
      "another account's charge moved or vanished under an update/delete that should have matched nothing"
  end

  test "the app role is refused every way of switching the boundary off" do
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


  test "no account-scoped table is unprotected, with a planted one as the control" do
    connection = ActiveRecord::Base.connection

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


  test "the identity dies with the transaction that set it" do
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
    connection = ActiveRecord::Base.connection
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


  test "a /v1 read under the app role sees exactly the caller's account" do
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
    without_identity do
      as_app_role do
        assert_equal "42501", refusal(<<~SQL), "a customer was written with no identity at all"
          insert into customers (owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
        SQL

        acts_as(FRESH_A)
        post "/v1/customers", params: { processor: "stripe", email: "isolation@example.com" }, as: :json
        assert_response :created
        assert_equal FRESH_A, json_body.dig("owner", "id")

        assert_equal 1, count(<<~SQL), "the request answered 201 and wrote nothing"
        SQL
      end
    end
  end

  test "a signed Stripe webhook resolves its own account, where the same row is invisible without one" do
    insert_customer(FRESH_A, INVOICE_CUSTOMER)

    without_identity do
      as_app_role do
        assert_equal 0, count("select count(*) from customers where processor_customer_id = #{quote(INVOICE_CUSTOMER)}"),
          "the customer was readable with no identity, so the webhook below would pass without resolving anything"

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

  def subscriptions_of(account_id)
    count("select count(*) from subscriptions where account_id = #{quote(account_id)}")
  end

  def charges_of(account_id)
    count("select count(*) from charges where account_id = #{quote(account_id)}")
  end

  def table_privileges(table, role = APP_ROLE)
    %w[SELECT INSERT UPDATE DELETE TRUNCATE].select do |privilege|
      ActiveRecord::Base.connection.select_value(
      )
    end
  end

  def customers_of(account_id)
    count("select count(*) from customers where owner_type = 'Account' and owner_id = #{quote(account_id)}")
  end

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



  def insert_customer(account_id, processor_customer_id)
    id = SecureRandom.uuid
    as_owner_role do
      as_account(account_id) do
        execute(<<~SQL)
          insert into customers (id, owner_type, owner_id, processor, processor_customer_id, metadata, created_at, updated_at)
        SQL
      end
    end
    id
  end

  def insert_plan
    id = SecureRandom.uuid
    execute(<<~SQL)
      insert into plans (id, name, slug, processor_price_id, amount_cents, currency, interval, trial_days, active, entitlements, created_at, updated_at)
    SQL
    id
  end

  def insert_subscription(account_id, customer_id, processor_subscription_id)
    id = SecureRandom.uuid
    as_owner_role do
      as_account(account_id) do
        execute(<<~SQL)
          insert into subscriptions (id, account_id, customer_id, plan_id, processor_subscription_id, status, created_at, updated_at)
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
        SQL
      end
    end
    id
  end
end
