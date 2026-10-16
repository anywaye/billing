class AccountIsolation < ActiveRecord::Migration[8.1]
  # The account boundary, enforced by Postgres as well as by Ruby.
  #
  # WHAT THIS ADDS. Until now billing's boundary was entirely application-level:
  # `scope :for_account` on `Customer`, `Subscription` and `Charge`, and every
  # `/v1` read reaching its row through one of them. That boundary is unchanged
  # and is still the one that decides a status code (a uuid naming another
  # account's row resolves to `nil` and the action answers 404, because a 403
  # would tell a caller walking ids which ones exist). What this migration adds is
  # the second half: the same boundary in the database, so that one forgotten
  # `for_account` — or one `find_by_sql` — reads zero rows instead of another
  # tenant's, and a write into somebody else's account is refused with SQLSTATE
  # 42501 rather than written.
  #
  # THREE TABLES, NOT SEVEN. `subscriptions` and `charges` spell the key
  # `account_id`, so `cafaye.protect_table` writes their whole boundary.
  # `customers` spells the same key `owner_type`/`owner_id` and has no
  # `account_id` column, so `protect_table` refuses it — measured:
  #
  #   ERROR:  cafaye.protect_table(customers, billing_app): the table has no
  #           account_id column, so there is nothing to scope it by.
  #
  # — and its four policies are hand-written in `db/tenancy/account_isolation.sql`,
  # which is where the reasoning for the predicate and for the one exemption on
  # that table lives. `plans`, `processor_webhooks`, `idempotency_keys` and
  # `outbox_events` are deliberately untouched: `plans` is the platform catalogue
  # (what an account may buy, not what it owns) and the other three are not
  # tenant rows — the outbox is drained across every account by one publisher, so
  # an `account_id` policy on it would be a lie.
  #
  # WHERE THE DDL LIVES, AND WHY IT IS TWO FILES RATHER THAN THIS ONE.
  # `db/tenancy/substrate.sql` is kit's template at the ref this copy was taken
  # from (kit `46d08f2`, sha256 `eaab2893…`; billing's own `kit.ref` predates the
  # template's existence, so the copy names the ref it came from rather than the
  # pin), kept as a standalone file so it stays comparable by hash to kit's. The
  # rest — the two `protect_table` calls and `customers`' five policies — is
  # `db/tenancy/account_isolation.sql`. Both are read here rather than inlined for
  # one reason that is not tidiness: `cafaye/core/harness/bin/tenancy-check` reads
  # `.sql` DDL and cannot read a Ruby migration, so `tenancy.yml`'s
  # `databaseEnforced: true` is only checkable while the DDL is in files it can
  # open.
  #
  # WHAT THIS MIGRATION DOES NOT DO: it does not call `cafaye.begin_account/1`.
  # That function is `set_config(..., is_local => true)` — transaction-local — so
  # a migration calling it outside a transaction sets an identity that is already
  # gone, and one calling it inside a migration transaction sets an identity that
  # expires when the migration commits. The identity is set per REQUEST, inside
  # the request's own transaction: `V1::BaseController#with_account_scope` for the
  # token-authenticated surface and `Webhooks::StripeController` for the
  # signature-authenticated one.
  #
  # THE TWO ROLES. Every policy names `billing` and `billing_app`. `billing` owns
  # the tables (it ran this migration) and `billing_app` owns nothing and holds
  # DML only, so the role a request logs in as cannot `alter table … disable row
  # level security`, drop a policy or truncate around one. FORCE is what makes the
  # owner's own reads subject to the policies too: without it the owner is exempt,
  # and a service whose background work and migrations run as the owner reads
  # every account's rows while the policies sit in the catalog looking like a
  # boundary. Both roles must exist on the cluster before this runs — kit's
  # `10-cluster.sh` provisions them for a compose cluster, and the message
  # `protect_table` raises names the missing one.

  # The tables this migration protects, in the order the DDL protects them. Named
  # here as well as in the DDL because `down` has to undo exactly what `up` did,
  # and because a table added to one list and not the other is what the sweep in
  # `up` and the isolation suite both report.
  PROTECTED = %w[subscriptions charges customers].freeze

  def up
    execute substrate
    execute account_isolation

    # THE MIGRATION'S OWN PROOF, run as it completes. `unprotected_tables()`
    # answers one row per account-scoped table in the schemas this substrate was
    # applied to that is not protected. It is not a substitute for the suite's
    # check — this runs once, the suite's runs every time — it is here so that a
    # table added to the fleet's vocabulary later, or a `protect_table` call that
    # silently did nothing, fails at the moment of the change rather than in a
    # test somebody is not running.
    unprotected = select_values(<<~SQL)
      select table_name from cafaye.unprotected_tables()
    SQL
    return if unprotected.empty?

    raise "these tables carry account_id and are not protected: #{unprotected.join(', ')}"
  end

  def down
    # Undo the boundary and nothing else. This migration created no table and
    # changed no column: what it owns is the policies, the two indexes
    # `protect_table` created, the ENABLE/FORCE bits and the `cafaye` schema.
    PROTECTED.each do |table|
      policies =
        if table == "customers"
          %w[select insert update delete resolve]
        else
          %w[select insert update delete]
        end

      policies.each do |action|
        execute "drop policy if exists #{table}_cafaye_#{action} on #{table}"
      end
      execute "drop index if exists #{table}_cafaye_account_id_idx"
      execute "alter table #{table} no force row level security"
      execute "alter table #{table} disable row level security"
    end

    execute "drop schema if exists cafaye cascade"
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
