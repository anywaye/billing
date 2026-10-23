# The one place this service writes the database's account identity.
#
# Every account-scoped table carries row-level security policies whose predicate
# is `account_id = (select anywaye.current_account_id())` (or, for `customers`,
# `owner_type = 'Account' and owner_id = (select anywaye.current_account_id())`),
# and `anywaye.current_account_id()` reads a transaction-local GUC. So the boundary
# is only as good as the number of places that set it: this class is that place,
# and there is exactly one caller per surface —
# `V1::BaseController#with_account_scope` for the token-authenticated API and
# `Webhooks::StripeController` for the signature-authenticated processor surface.
#
# WHY THE IDENTITY IS TRANSACTION-LOCAL, and it is the whole design rather than a
# detail. `anywaye.begin_account/1` is `set_config(..., is_local => true)`, and
# every process here holds a connection POOL:
#
#   * A session-level value would go back to the pool still carrying tenant A's
#     identity, and the next request on that connection — tenant B's — would be
#     handed it. Transaction-local cannot outlive the request.
#   * The cost of that choice is stated rather than hidden: outside an explicit
#     transaction the setting expires at the end of the statement that set it, so
#     a caller reaching the database in autocommit reads zero rows. That cannot
#     leak, and it is loud rather than silent — a service that suddenly sees none
#     of its own data fails its first integration test.
#
# WHY THIS IS NOT A `before_action`. A `before_action` runs before the action's
# transaction exists, so the identity it set would be gone by the first query —
# the transaction has to OPEN the scope and the identity has to be set inside it,
# which is why both callers wrap the work in `with_account` rather than setting a
# variable earlier.
#
# AND IT IS SET ONCE PER REQUEST, which is a rule about SAVEPOINTS rather than
# about tidiness. A nested `ActiveRecord::Base.transaction do` is a SAVEPOINT, and
# a GUC set inside one that is RELEASED survives into the enclosing transaction —
# only the outermost COMMIT/ROLLBACK reverts it. Measured on this cluster:
#
#   begin;
#   select anywaye.begin_account('1111…');        -- A
#   savepoint s;
#   select anywaye.begin_account('2222…');        -- B
#   release savepoint s;
#   select anywaye.current_account_id();          -- 2222…   <-- the trap
#   commit;
#   select anywaye.current_account_id();          -- NULL
#
# So code inside a request that called `begin_account` again — in a nested
# transaction, in a test helper — would leave the identity changed for the rest of
# the request. That is why this module has no "as another account" helper for
# production code: a request acts as one account, and the account it acts as is
# the claim it was verified with.
module Tenancy
  module_function

  # Run the block inside a transaction whose identity is `account_id`, and let
  # the identity die with it. A `nil` account CLEARS rather than failing — the
  # substrate's own convention — so a caller that could not resolve an account
  # runs in a scope that reads nothing instead of one that reads everything.
  #
  # `joinable: false`, and it is not a detail: it is what keeps a nested
  # `transaction do` INSIDE a request behaving the way every caller in this service
  # already assumes. Rails joins a joinable open transaction rather than opening a
  # savepoint, so a request-wide transaction that was joinable turned
  # `Checkout::Session`'s `Subscription.transaction do … end` into a no-op — and
  # that block is where an expected unique violation is contained. Measured:
  # `POST /v1/checkouts` for a plan the account already holds one live subscription
  # on answered **500** instead of 422, because `subscriptions_live_account_plan_idx`
  # aborted the REQUEST's transaction, the `rescue ActiveRecord::RecordNotUnique`
  # that names the refusal caught the exception over an already-aborted
  # transaction, and the next statement failed with 25P02. Non-joinable restores
  # the savepoint per nested transaction, which is the shape the code was written
  # against; atomicity is unchanged, because a released savepoint still commits
  # with the transaction that contains it.
  def with_account(account_id)
    ApplicationRecord.transaction(joinable: false) do
      begin_account(account_id)
      yield
    end
  end

  # The identity itself. One function, one place, so "where does the database
  # learn which account this is" has one answer in this repository.
  def begin_account(account_id)
    execute_function("anywaye.begin_account", account_id)
  end

  # `with_account` for a request that has to WORK OUT which account it is, and
  # the difference is not stylistic. `resolution` answers `account_id`, and it has
  # to run INSIDE the transaction: working out the account means presenting a
  # value (`anywaye.begin_credential/1`), and that is `set_config(..., is_local =>
  # true)` like `begin_account/1` — outside a transaction the presented value is
  # gone before the lookup that uses it. The webhook path is the one caller; see
  # `Webhooks::AccountResolution` for why a signature-authenticated request cannot
  # have its account handed to it the way a token-authenticated one can.
  def with_resolved_account(resolution)
    ApplicationRecord.transaction(joinable: false) do
      begin_account(resolution.account_id)
      yield
    end
  end

  # The OTHER seam, and the only other one this service uses: the value a caller
  # PRESENTS to resolve a row it cannot yet name an account for. See
  # `db/tenancy/account_isolation.sql` — `customers_anywaye_resolve` — and
  # `Webhooks::AccountResolution`, which is its one caller.
  def begin_credential(presented_value)
    execute_function("anywaye.begin_credential", presented_value)
  end

  # What Postgres thinks the identity is, read back from the connection. Used by
  # the isolation suite, which asserts the value the database holds rather than
  # the value Ruby set — and by nothing in the request path.
  def current_account_id
    ApplicationRecord.connection.select_value("select anywaye.current_account_id()")
  end

  def execute_function(name, argument)
    connection = ApplicationRecord.connection
    # `quote` renders nil as NULL, which is what clears: the substrate's
    # `begin_account(NULL)` and `begin_credential(NULL)` both write the empty
    # string, and an empty GUC reads as "no identity" rather than as a value.
    connection.execute("select #{name}(#{connection.quote(argument)})")
  end
end
