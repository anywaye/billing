class AccountIsolation < ActiveRecord::Migration[8.1]
  PROTECTED = %w[subscriptions charges customers].freeze

  def up
    execute substrate
    execute account_isolation

    unprotected = select_values(<<~SQL)
      select table_name from anywaye.unprotected_tables()
    SQL
    return if unprotected.empty?

    raise "these tables carry account_id and are not protected: #{unprotected.join(', ')}"
  end

  def down
    PROTECTED.each do |table|
      policies =
        if table == "customers"
          %w[select insert update delete resolve]
        else
          %w[select insert update delete]
        end

      policies.each do |action|
        execute "drop policy if exists #{table}_anywaye_#{action} on #{table}"
      end
      execute "drop index if exists #{table}_anywaye_account_id_idx"
      execute "alter table #{table} no force row level security"
      execute "alter table #{table} disable row level security"
    end

    execute "drop schema if exists anywaye cascade"
  end

  private

  # kit's tenancy substrate, byte-identical to
  # `kit/templates/database/tenancy/substrate.sql` at the ref the copy was taken
  # from. Read rather than inlined so the copy stays comparable by hash.
  def substrate
    read_tenancy_file("substrate.sql")
  end

  # billing's own half of the boundary: the `protect_table` calls and the
  # hand-written policies for the table whose key is not spelled `account_id`.
  def account_isolation
    read_tenancy_file("account_isolation.sql")
  end

  def read_tenancy_file(name)
    path = Rails.root.join("db/tenancy", name)
    raise "the tenancy DDL is missing from #{path}" unless path.exist?

    path.read
  end
end
