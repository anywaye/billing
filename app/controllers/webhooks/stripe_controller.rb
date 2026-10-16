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

    # Stripe's own default, and the window in which a captured request stays
    # replayable. Overridable because a deployment may legitimately receive a
    # request later than Stripe sent it — but the check is always performed
    # against the timestamp Stripe signed, never a number this service invented.
    DEFAULT_TOLERANCE = 300

    def create
      payload = verified_payload
      # The account the event belongs to, and the request's own transaction —
      # because the database half of the boundary needs an identity before the
      # first row is read, and this request has no token to read one from. The
      # resolution presents an id the payload carried (see
      # `Webhooks::AccountResolution`); a payload that names no customer this
      # service knows resolves to nil, and the ingestion then reads nothing and
      # records the delivery as `unknown_customer`, which is what it did for a
      # dashboard-created customer before any of this existed.
      #
      # AFTER `verified_payload`, never before: an unverified body is not an event
      # and must not be interpreted — not even well enough to present one of its
      # ids to the database.
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
        # Parsed from the verified bytes, not from the gem's event object: the
        # stored payload is then the body Stripe signed rather than a round trip
        # through a third-party object model. `id` and `type` come from the
        # verified event, so a payload cannot disagree with the signature that
        # covered it about which event it is.
        payload = JSON.parse(raw_body)
        # Not an object, so not an event — and this has to be decided here rather
        # than by whatever the gem does with it. `Stripe::Webhook.construct_event`
        # builds a `Stripe::Event` out of the parsed body, and an array, a bare
        # number, a string, a boolean or `null` reach that call as something it
        # has no accessor for, so it raises `TypeError` or `NoMethodError` rather
        # than the `SignatureVerificationError` the loop above rescues. Uncaught,
        # that is a 500 on an endpoint whose own status table says a 5xx never is
        # an answer, because a 5xx teaches a processor to retry a decision that
        # cannot change. `{}` passes here and is refused one line below for having
        # no event id, which is the same 400 with the same detail.
        raise MalformedEvent, "verified body is not a JSON object" unless payload.is_a?(Hash)

        payload = payload.merge("id" => event.id, "type" => event.type)
        raise MalformedEvent, "verified body is not an event" if payload["id"].blank? || payload["type"].blank?

        payload
      rescue JSON::ParserError => e
        raise MalformedEvent, e.message
      end

      def verify_signature
        raise SignaturesUnconfigured, "no STRIPE_WEBHOOK_SECRET is configured" if signing_secrets.empty?

        # Every configured secret is tried and the first that verifies wins, the
        # way the reference processor does it. A body that verifies under none of
        # them — or under a stale timestamp, which is what the tolerance window
        # exists for — is a rejected signature and a 400.
        #
        # The exception list is this method's and not `create`'s, because this is
        # where the gem is called and this is what it raises. `StandardError` is
        # last on purpose: it catches the gem's own shape assumptions on a body it
        # verified, and it is scoped to the verification call so it cannot swallow
        # anything from the ingestion layer below. The loop's own
        # `SignatureVerificationError` stays first and stays a `next`, so a secret
        # that simply does not match is a candidate failure and not an error.
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
