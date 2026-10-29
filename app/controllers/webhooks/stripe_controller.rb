module Webhooks
  # Stripe's webhook endpoint: POST /v1/webhooks/stripe
  #
  # Verified with `Stripe::Webhook.construct_event` and nothing else. This service
  # receives from Stripe; it does not call the Stripe API. A signature that does
  # not verify is a body we did not receive, so it is refused and stored nowhere
  # — an unverified payload is not an event, and writing one would put an
  # attacker's JSON in the row a human reads when something is wrong.
  #
  # Statuses, all of them deliberate:
  #
  #   200 — a verified event, whatever became of it. A replay, an unknown type, a
  #         type we deliberately ignore, and an event whose mapping raised all
  #         answer 200, because each is recorded and terminal, and a processor
  #         retrying them reaches the identical outcome. A 5xx here would teach
  #         Stripe to retry a decision this service has already made, and would
  #         hide a parked row behind a timeout.
  #   400 — the signature did not verify, or the body was not an event. The
  #         sender's problem, and a 4xx is what stops a retry loop.
  #   503 — our own signing secret is not configured. Not 400: telling Stripe its
  #         signature is bad when we cannot check it at all sends an operator
  #         looking in exactly the wrong place. The cause is logged; the body says
  #         only that the service is unavailable.
  #
  # The problem bodies are the ones `ProblemResponses` builds, so the code is one
  # of core's reserved list and the trace id matches the `X-Trace-Id` header, the
  # same as a 422 from the `/v1` API.
  class StripeController < BaseController
    # Raised when a verified signature covers a body that is not an event at all:
    # unparseable JSON, or JSON with no event id or no type. There is nothing to
    # store — a row with no event id could never be deduplicated, and one with no
    # type could never be routed — so this is a 400 rather than a parked row.
    class MalformedEvent < Webhooks::Error; end

    # Raised when no signing secret is configured at all. Our misconfiguration,
    # never the sender's, and it must not be reported as a signature failure.
    class SignaturesUnconfigured < Webhooks::Error; end

    # Raised when a signature is well-formed but did not verify under any
    # configured secret. Its own class rather than the gem's, because the gem's
    # constructor wants the header it failed to parse and because "no configured
    # secret verified this" is a conclusion of ours, not a parse failure.
    class UnverifiedSignature < Webhooks::Error; end

    DEFAULT_TOLERANCE = 300

    def create
      payload = verified_payload
      Tenancy.with_resolved_account(Webhooks::AccountResolution.new(payload)) do
        Webhooks::Ingestion.new(
          processor: :stripe,
          event_id: payload["id"],
          type: payload["type"],
          payload: payload
        ).call
      end
      head :ok
    rescue SignaturesUnconfigured => e
      unavailable(e)
    rescue UnverifiedSignature, Stripe::SignatureVerificationError, MalformedEvent => e
      reject(e)
    end

    private
      def verified_payload
        event = verify_signature
        payload = JSON.parse(raw_body)
        raise MalformedEvent, "verified body is not a JSON object" unless payload.is_a?(Hash)

        payload = payload.merge("id" => event.id, "type" => event.type)
        raise MalformedEvent, "verified body is not an event" if payload["id"].blank? || payload["type"].blank?

        payload
      rescue JSON::ParserError => e
        raise MalformedEvent, e.message
      end

      def verify_signature
        raise SignaturesUnconfigured, "no STRIPE_WEBHOOK_SECRET is configured" if signing_secrets.empty?

        signing_secrets.each do |candidate|
          begin
            return Stripe::Webhook.construct_event(raw_body, signature, candidate, tolerance: tolerance)
          rescue Stripe::SignatureVerificationError
            next
          rescue StandardError => e
            raise MalformedEvent, "#{e.class}: #{e.message}"
          end
        end

        raise UnverifiedSignature, "no configured secret verified the signature"
      end

      def signature
        signature_header("Stripe-Signature").to_s
      end

      # Every secret configured for this endpoint. Normally one; two during a
      # rotation, so the window in which Stripe still signs with the old secret
      # does not turn into a 400 for every real event.
      def signing_secrets
        list = ENV["STRIPE_WEBHOOK_SECRETS"].presence&.split(",")
        (list || [ ENV["STRIPE_WEBHOOK_SECRET"] ]).compact_blank
      end

      def tolerance
        Integer(ENV.fetch("STRIPE_WEBHOOK_TOLERANCE", DEFAULT_TOLERANCE))
      rescue ArgumentError, TypeError
        Rails.logger.error("STRIPE_WEBHOOK_TOLERANCE is not an integer; using the default")
        DEFAULT_TOLERANCE
      end

      # 400 for everything the sender got wrong: a signature that did not verify,
      # or a verified body that is not an event. The detail distinguishes them,
      # because "your signature is bad" and "that body is not an event" send an
      # operator to two entirely different places, and the response is the only
      # thing they have.
      def reject(exception)
        Rails.logger.warn("stripe webhook rejected: #{exception.class}: #{exception.message}")
        render_problem(:bad_request, detail: rejection_detail(exception))
      end

      def rejection_detail(exception)
        if exception.is_a?(MalformedEvent)
          "The verified body is not a Stripe event."
        else
          "The Stripe-Signature header did not verify against the request body."
        end
      end

      def unavailable(exception)
        Rails.logger.error("stripe webhook cannot verify signatures: #{exception.class}: #{exception.message}")
        render_problem(:unavailable, detail: "Webhook signature verification is not configured.")
      end
  end
end
