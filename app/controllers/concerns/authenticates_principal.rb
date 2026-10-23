# Who is calling, on `/v1` and nowhere else.
#
# ## Where this sits, and why it is not a middleware
#
# A middleware would put the check on paths, and the paths here are the thing that
# must not be got wrong: `/v1/customers` is a anywaye client surface,
# `/v1/webhooks/stripe` is a *processor* surface authenticated by signature, and
# `/healthz` is infrastructure. A path-prefixed check gets "all of /v1" wrong in the
# direction that matters — it would put a token requirement on the webhook, which
# core's conventions forbid ("Inbound webhooks are **not** JWT-authenticated") and
# which would be a second, weaker trust path to the same door.
#
# So this is a `before_action` on `V1::BaseController`, and it is inherited by
# exactly the three controllers the router draws inside `scope "/v1", module: :v1`.
# `Webhooks::BaseController` does not inherit from it, cannot reach it, and
# `config.action_controller.raise_on_missing_callback_actions = true` means a
# future controller in that namespace cannot silently skip the filter by not
# naming an action. `test/authentication/principal_lock_test.rb` asserts the
# boundary from the router's own table rather than from this paragraph.
#
# ## The three refusals, and the statuses
#
#   * `Identity::Unconfigured`, `Identity::Unreachable` -> **503**. This service
#     cannot check the credential right now. A 401 would tell a caller holding a
#     valid token to go and rotate it, which is the wrong instruction and sends an
#     operator to the wrong system — the same reasoning the webhook uses when the
#     signing secret is missing, and the same one `Problem::CATALOG`'s 503 title
#     exists for.
#   * `Identity::Invalid`, and a request with no bearer token at all -> **401**.
#
# **The failure mode that matters is the one that degrades OPEN.** There is no
# branch anywhere in this file that lets a request through without a verified
# principal: no default account, no "authentication is disabled in development",
# no rescue that renders a 200. If the verifier is missing, broken, or cannot reach
# identity, `/v1` is locked, and that is asserted rather than asserted-in-prose.
#
# ## 401, never 403
#
# `Problem::CATALOG` has no 403 and this file does not add one. A caller whose
# token is fine but who asked about somebody else's row gets the **same 404** a
# caller asking about a row that does not exist gets — absence, never refusal —
# because a 403 says "this exists, you may not have it", which is an enumeration
# oracle. The mechanism for that is `for_account`, not a status.
module AuthenticatesPrincipal
  extend ActiveSupport::Concern

  # RFC 7235's registered scheme. `Bearer` case-insensitively, per the
  # specification: the scheme is compared ASCII-case-insensitively, and a proxy or
  # a client library that lowercases it is not an attacker.
  BEARER = /\ABearer[ \t]+(?<token>\S+)\z/i.freeze

  # One fixed sentence for every refused token. Which of the four things was wrong
  # — signature, expiry, issuer, audience — is not something a caller learns by
  # trying, and `detail` on a problem document is the one field that could carry
  # it. The specific reason goes to the log with the trace id.
  UNAUTHORIZED_DETAIL = "This request needs a bearer token issued by this platform's identity service."

  # This service cannot verify anybody right now. Also one sentence: an operator
  # reads the log, not the body, and the body saying which environment variable is
  # missing would be telling an unauthenticated caller about this deployment.
  UNAVAILABLE_DETAIL = "This service cannot verify a caller right now."

  included do
    before_action :authenticate_principal!
  end

  # The verified caller. A `NoMethodError` here would be an accident, so it is
  # defined once on the concern rather than expected of every includer.
  def current_principal
    @current_principal
  end

  private
    # The verified caller, or a rendered refusal that stops the action.
    def authenticate_principal!
      @current_principal = verified_principal
    rescue Identity::Unconfigured, Identity::Unreachable => e
      Rails.logger.error("[#{trace_id}] #{request.path}: #{e.class}: #{e.message}")
      render_problem(:unavailable, detail: UNAVAILABLE_DETAIL)
    rescue Identity::Invalid => e
      Rails.logger.error("[#{trace_id}] #{request.path}: #{e.class}: #{e.message}")
      render_problem(:unauthorized, detail: UNAUTHORIZED_DETAIL)
    end

    def verified_principal
      Identity::TokenVerifier.current.verify(bearer_token)
    end

    # The credential, or nil. **Absent is a refusal and not a bypass**: the caller
    # below turns nil into `Identity::Invalid`, which is the 401.
    #
    # Exactly one header, exactly one token. `request.headers["Authorization"]`
    # joins repeated headers with a comma in Rack, so a request carrying two is
    # one string with a comma in it and will not match the pattern — which is the
    # right answer, since which of two credentials to honour is a question with no
    # safe default.
    def bearer_token
      header = request.headers["Authorization"]
      return nil if header.blank?

      match = BEARER.match(header.strip)
      raise Identity::Invalid, "authorization header is not a bearer credential" if match.nil?

      match[:token]
    end

    # The caller's account, and the only tenancy key a query on this surface may be
    # scoped by. A method rather than a bare `current_principal.account_id` at every
    # call site so that "where does the account come from" has one answer in the
    # repository.
    def current_account_id
      current_principal.account_id
    end
end
