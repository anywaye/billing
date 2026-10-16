# What /v1 has in common, which is less than it looks like: the version prefix
# is routing's job, and everything else about a response comes from the
# concerns on ApplicationController.
#
# # The authorization boundary is here, and it is here rather than on
# `ApplicationController` for one reason
#
# `ApplicationController` is the ancestor of `HealthController`,
# `ErrorsController` **and** `Webhooks::BaseController`. Putting a token check
# there would put it on the probes — which must answer with no credential so an
# orchestrator can ask whether the process is alive — and on the Stripe webhook,
# which authenticates by signature over the raw body and must never grow a
# `Bearer`.
#
# Including the concern here means the boundary is **structural**: it is inherited
# by the three controllers the router draws inside `scope "/v1", module: :v1`, and
# by nothing else. A controller added to `/v1` tomorrow inherits it without being
# asked, because `raise_on_missing_callback_actions` is on and the filter names
# no action.
module V1
  class BaseController < ApplicationController
    include AuthenticatesPrincipal

    # The database half of the boundary, turned on for every request that reaches
    # this class. Every account-scoped table carries row level security policies
    # written by `cafaye.protect_table` — and, for `customers`, by hand, see
    # `db/tenancy/account_isolation.sql` — and those policies read
    # `cafaye.current_account_id()`, a GUC set once per request inside the
    # request's own transaction. So a query that forgot its `where account_id = ?`
    # reads zero rows rather than another business's rows, and `for_account` is
    # defence in depth rather than the only defence.
    #
    # `around_action` rather than `before_action`, and the ORDER here is
    # load-bearing rather than decoration: `authenticate_principal!` is a
    # `before_action` added by the concern above, and a `before_action` declared
    # before an `around_action` runs BEFORE it. Measured on ActiveSupport's own
    # callback chain, which is the mechanism `_process_action_callbacks` compiles:
    #
    #   set_callback :action, :before, :first
    #   set_callback :action, :around, :wrapper
    #   set_callback :action, :before, :second
    #   -> ["before_first", "around_open", "before_second", "action", "around_close"]
    #
    # So the token is verified first and `current_account_id` is the verified claim
    # by the time this wraps the action. A `before_action` here would set the
    # identity OUTSIDE the transaction that carries the queries, and
    # `set_config(..., is_local => true)` outside a transaction expires at the end
    # of the statement that set it — so the first query of every request would read
    # zero rows. See `Tenancy`.
    around_action :with_account_scope

    private
      # The request's own transaction, with the token's account as the database's
      # identity. The account is the verified claim and never a body field or a
      # path segment: `POST /v1/customers` stamps it onto the row it writes, and a
      # caller naming their own account is the one thing
      # `AuthenticatesPrincipal` exists to forbid.
      def with_account_scope(&action)
        account_id = current_account_id
        return action.call if account_id.blank?

        Tenancy.with_account(account_id, &action)
      end

      # Postgres parses a `uuid` column before Rails gets to decide whether a
      # row exists, so `find` with a malformed id is a database error rather
      # than a missing record. An id that cannot be one of ours is a 404, and
      # that has to be decided before the query, not after the exception.
      def uuid_param!(value)
        raise ActiveRecord::RecordNotFound unless Identifiers::UUID.match?(value.to_s)

        value
      end
  end
end
