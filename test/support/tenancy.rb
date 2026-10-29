module TestSupport
  module DatabaseTenancy
    OWNER_ROLE = "billing".freeze
    APP_ROLE = "billing_app".freeze

    def as_account(account_id)
      previous = database_identity
      ::Tenancy.begin_account(account_id)
      yield
    ensure
      begin
        ::Tenancy.begin_account(previous.presence)
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

    def without_identity(&block)
      as_account(nil, &block)
    end

    def database_identity
      ActiveRecord::Base.connection.select_value("select anywaye.current_account_id()")
    end

    def as_owner_role(&block)
      as_role(OWNER_ROLE, &block)
    end

    def as_app_role(&block)
      as_role(APP_ROLE, &block)
    end

    def as_role(role)
      connection = ActiveRecord::Base.connection
      connection.execute("set local role #{role}")
      yield connection
    ensure
      begin
        connection.execute("reset role")
      rescue ActiveRecord::StatementInvalid
        nil
      end
    end

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

    def table_boundary(table)
      ActiveRecord::Base.connection.select_rows(<<~SQL).first
        select c.relrowsecurity::int,
               c.relforcerowsecurity::int,
               (select count(*) from pg_policy p where p.polrelid = c.oid)::int,
               pg_get_userbyid(c.relowner)
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
      SQL
    end

    def policy_names(table)
      ActiveRecord::Base.connection.select_values(<<~SQL)
        select p.polname
        from pg_policy p
        join pg_class c on c.oid = p.polrelid
        join pg_namespace n on n.oid = c.relnamespace
        order by p.polname
      SQL
    end

    def role_attributes(role)
      row(<<~SQL)
        select rolsuper::int, rolbypassrls::int, rolcanlogin::int, rolcreatedb::int
      SQL
    end
  end
end

module ActiveSupport
  class TestCase
    include TestSupport::DatabaseTenancy
  end
end
