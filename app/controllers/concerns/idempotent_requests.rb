# `Idempotency-Key` on the mutating POSTs, per core's openapi-conventions.md.
#
# The controller asks two questions through this module and nothing else:
#
#   replayed_response  -> a stored [status, body] to send instead of doing the
#                         work again, or nil if the key is new
#   remember_response  -> store what was actually sent
#
# Keeping the storage behind those two calls is what makes the rules checkable:
# a retried POST must not write a second row, and a replay must return the
# bytes the client already saw rather than a freshly rendered equivalent.
module IdempotentRequests
  extend ActiveSupport::Concern

  HEADER = "Idempotency-Key"
  REPLAYED_HEADER = "Idempotency-Replayed"

  included do
    rescue_from IdempotencyKeyReused, with: :render_idempotency_key_reused
  end

  private
    # A nil principal on a controller that uses these methods. Named rather than
    # raised inline so the message names the seam rather than the symptom, and
    # documented on `idempotency_principal` below.
    class NoPrincipal < StandardError; end
    # The endpoint half of core's (endpoint, principal, key) scope. The
    # controller and action, so the same key on two endpoints is two keys.
    def idempotency_scope
      "#{controller_path}##{action_name}"
    end

    # **The principal half, and it is required rather than defaulted.**
    #
    # This concern is on `ApplicationController`, so `Webhooks::BaseController`
    # inherits it — and the webhook has no principal, because its sender is a
    # processor and not a anywaye client. It also never calls these two methods,
    # since it takes no `Idempotency-Key`. So this raises rather than inventing an
    # `"anonymous"` caller: the alternative is a default that is correct today
    # because nothing reaches it, and wrong the day a webhook or an unauthenticated
    # controller does.
    def idempotency_principal
      principal = current_principal
      raise NoPrincipal, "an Idempotency-Key reached a request with no verified principal" if principal.nil?

      principal.idempotency_principal
    end

    def idempotency_key
      request.headers[HEADER].presence
    end

    # A digest, not the body: the only question anyone asks is whether the body
    # is the same one, and holding a request payload for 24 hours to compare it
    # would be a liability in a service that stores payment data.
    def request_digest
      Digest::SHA256.hexdigest(request.raw_post.to_s)
    end

    # nil when there is no key, or when the key has not been used. Deliberately
    # silent about a fresh key: a request without a key is processed normally,
    # and so is the first use of one.
    def replayed_response
      key = idempotency_key
      return nil if key.nil?

      record = IdempotencyKey.replay_for(
        endpoint: idempotency_scope,
        principal: idempotency_principal,
        key: key,
        digest: request_digest
      )

      record && [ record.status, record.response_body ]
    end

    def render_replayed_response(replayed)
      status, body = replayed

      # On the response, not as a `render` option: `render` has no `headers:`
      # key and passing one would be silently dropped, which is exactly the kind
      # of bug where the replay works and the client is never told it was one.
      response.headers[REPLAYED_HEADER] = "true"

      render json: JSON.parse(body), status: status
    end

    # Called *after* the response is rendered, and takes the body that was
    # rendered. The status comes from the response rather than from the caller,
    # so the stored status cannot drift from the status that was actually sent —
    # which is the whole point of a replay.
    def remember_response(body)
      key = idempotency_key
      return if key.nil?

      IdempotencyKey.remember(
        endpoint: idempotency_scope,
        principal: idempotency_principal,
        key: key,
        digest: request_digest,
        status: response.status,
        body: body.to_json
      )
    end

    def render_idempotency_key_reused(_exception)
      render_problem(
        :idempotency_key_reused,
        detail: "This Idempotency-Key was already used for a different request body. Use a new key, or resend the original body."
      )
    end
end
