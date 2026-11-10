# frozen_string_literal: true

module V1
  module Service
    # The service-to-service surface: metering calls from platform services that
    # are not end users and hold no identity token.
    #
    # ## Why this exists separately from V1::BaseController
    #
    # `V1::BaseController` authenticates an identity principal and scopes every
    # query to that account. A metering caller is a *service* (boax, ship, …),
    # not a person: it has no identity account, and the entity it meters against
    # lives in its own database. So this surface authenticates a shared service
    # token and keys wallets by a namespaced owner string the service supplies.
    #
    # ## Fail closed
    #
    # If `BILLING_SERVICE_TOKEN` is unset the surface answers 503 and every call
    # is refused. There is no default token and no development bypass: a
    # metering endpoint that degrades open is a free-usage hole.
    #
    # ## The owner key
    #
    # `owner_key` is an opaque string the service chooses, and it is the wallet's
    # owner id. It should be namespaced (`boax:org_123`) so two services cannot
    # collide. It is stored verbatim; billing never parses it.
    class BaseController < ApplicationController
      before_action :authenticate_service!

      private
        def authenticate_service!
          expected = ENV["BILLING_SERVICE_TOKEN"].to_s
          if expected.empty?
            render_problem(:unavailable, detail: "Service metering is not configured on this deployment.")
            return
          end
          presented = bearer_token
          unless presented && ActiveSupport::SecurityUtils.secure_compare(presented, expected)
            render_problem(:unauthorized, detail: "This request needs the platform service token.")
          end
        end

        def bearer_token
          header = request.headers["Authorization"].to_s
          match = header.match(/\ABearer[ \t]+(?<token>\S+)\z/i)
          match && match[:token]
        end

        def wallet
          @wallet ||= Ask::Tokens.wallet_for(ExternalTokenOwner.new(params[:owner_key]))
        end
    end
  end
end
