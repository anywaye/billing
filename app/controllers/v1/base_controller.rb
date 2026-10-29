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
