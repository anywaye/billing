module Processor
  # The whole of this service's outbound surface to Stripe.
  #
  # Five methods, and every Stripe call in this repository is one of them. That
  # is deliberate: "billing receives from Stripe" is only a claim about the code
  # while there is nowhere else for a `Stripe::` call to be. Adding a sixth
  # method is adding a capability, and the diff says so.
  #
  # The `api` keyword is the seam. Production passes nil and gets the `stripe`
  # gem; the specs pass a recorder and assert on what was *asked*. Both are the
  # same class, so a test exercises the argument building rather than a parallel
  # implementation of it — the failure mode a hand-written double invites.
  #
  # ## Nothing here is arithmetic about money
  #
  # A checkout session sends a price id. A plan change sends a proration
  # *behaviour*. A cancellation sends an id and a boolean. An upcoming invoice
  # sends two ids and receives the processor's projection back. No amount is
  # ever computed in this file, and the specs assert the absence of the keys
  # that would carry one (`amount`, `credit`, `refund`, `prorate`).
  #
  # That is not tidiness. A figure calculated in Ruby and sent to the processor is
  # a figure this service did not keep, and the two eventually disagree — in a
  # customer's invoice, which is the worst place to find out.
  class StripeClient
    # No api key configured. This service's misconfiguration, never the caller's:
    # the same reasoning the webhook endpoint uses to answer 503 rather than 400
    # when a signing secret is missing.
    class Unconfigured < Error; end

    # The destination plan has no processor price, so there is nothing to move a
    # subscription onto. Refused before the request, because a request that cannot
    # mean anything should not be sent.
    class Unpriced < Error; end

    # The processor said no. One class for every refusal, whatever the call, so a
    # caller handles "Stripe refused" once and the processor's own message and the
    # identifier that was refused both travel with it.
    class RequestFailed < Error; end

    # The processor stated a figure this service cannot carry. Stripe's 2025
    # line items report `pricing.unit_amount_decimal` as a decimal STRING —
    # integral for every flat price this service sells, and legitimately
    # fractional for metered ones. Billing::Money here is integer minor units and
    # nothing rounds, so a fractional unit amount is refused rather than
    # truncated: a truncated one would be a figure the processor never stated.
    class Unrepresentable < Error; end

    class << self
      # The client the application uses, built from the environment.
      #
      # A seam rather than a constant, for two reasons. The specs need a recorder
      # instead of the network, and swapping the *object* keeps them exercising this
      # class's own argument building rather than a parallel implementation of it —
      # the failure mode a hand-written double invites. And the client is constructed
      # from `ENV` rather than memoized at boot, so a key that rotates is picked up
      # without a redeploy.
      def current
        @current ||= new
      end

      attr_writer :current
    end

    attr_reader :api_key

    def initialize(api_key: nil, api: nil)
      @api_key = (api_key || ENV["STRIPE_API_KEY"]).presence
      @api = api
    end

    # A hosted Checkout session for one plan, in subscription mode, so the
    # processor can collect the first payment and create the subscription itself.
    #
    # The subscription does not exist yet at this point and this service does not
    # pretend otherwise: no local row is written, and `created` is decided by the
    # webhook that follows. What is returned is the processor's session and the
    # processor's URL — a checkout URL is the processor's to generate, and one
    # assembled here would be a link to nothing.
    #
    # `customer_reference` is this service's own customer id, carried both as the
    # processor's `client_reference_id` and in the subscription's metadata. It is
    # the only link back we can set: `customers.processor_customer_id` is null for
    # every customer created through `/v1` in v0, so at this moment the processor
    # has no id of ours to match on. `processor_customer_id` is sent when we know
    # it, and nil is passed explicitly when we do not, which asks the processor to
    # create the customer and tell us about it in the subscription.
    # `success_url` and `cancel_url` are REQUIRED BY STRIPE on a hosted
    # session, and this was a production-breaking omission until the live
    # recording caught it: the hand-written double accepted a session with
    # no return URLs and minted a plausible one, while the real API refused
    # the request outright — the door that takes money could not open. Both
    # are the CALLER's, because this service is an API: where a buyer lands
    # after paying is the app's page, not a URL billing may invent.
    def create_checkout_session(plan_price_id:, customer_reference:, success_url:, cancel_url: nil, processor_customer_id: nil)
      require_configured!
      raise Unpriced, "the plan has no processor_price_id, so there is nothing to check out" if plan_price_id.blank?

      perform(:create_checkout_session, plan_price_id) do
        stripe.create_checkout_session(
          mode: "subscription",
          line_items: [ { price: plan_price_id, quantity: 1 } ],
          customer: processor_customer_id,
          client_reference_id: customer_reference,
          success_url: success_url,
          # Stripe renders its own "cancel" link back to the app; sending the
          # success URL is the honest default when the caller names no other,
          # because the alternative is whatever Stripe's dashboard default is.
          cancel_url: cancel_url.presence || success_url,
          subscription_data: {
            metadata: { cafaye_customer_id: customer_reference }
          }
        )
      end
    end

    # Moves a subscription onto another price, now or at the renewal, according to
    # the `proration_behavior` the caller decided. The behaviour is
    # Subscriptions::PlanChange's answer and this method does not second-guess it.
    def apply_plan_change(processor_subscription_id:, price_id:, proration_behavior: nil)
      require_configured!
      raise Unpriced, "the new plan has no processor_price_id, so there is nothing to move onto" if price_id.blank?

      # **A plan change is two requests, and the live recording is why.**
      # Stripe's 2025 API no longer replaces a subscription's items from a
      # price-id list: `items: [{ price: new }]` with no `id` APPENDS a
      # second item — measured, the fixture subscription came back holding
      # both prices — so a naive move would silently bill a customer for two
      # plans. The item being moved has to be named by ITS OWN id, and that
      # id is the processor's, read immediately before the move: retrieve the
      # subscription, take the active item, then update that item's price.
      #
      # One intent, two calls, and the class doc's claim is still the true
      # one — every Stripe call this service makes is inside one of these
      # five methods.
      perform(:apply_plan_change, processor_subscription_id) do
        item_id = stripe.retrieve_subscription(processor_subscription_id).items.data.first.id

        stripe.update_subscription(
          processor_subscription_id,
          { items: [ { id: item_id, price: price_id } ], proration_behavior: proration_behavior }.compact
        )
      end
    end

    # Cancels a subscription. `at_period_end` is the caller's decision and is sent
    # either way, including `false` — an absent key would mean "whatever the
    # processor's default is", and the whole point of the flag is that this
    # service chooses rather than inherits.
    #
    # No refund and no proration is asked for, and that is a decision rather than
    # an omission. Cancelling mid-period is the moment a service is most tempted
    # to compute "the three weeks they paid for and are not getting"; the
    # processor owns that number, and a refund invented here is a refund this
    # service did not keep.
    def cancel_subscription(processor_subscription_id:, at_period_end:)
      require_configured!

      perform(:cancel_subscription, processor_subscription_id) do
        stripe.update_subscription(processor_subscription_id, { cancel_at_period_end: at_period_end })
      end
    end

    # The processor's projection of the next invoice for a subscription: what the
    # customer will be charged at the renewal, before it is paid.
    #
    # Two identifiers go out and both are the processor's own: the subscription
    # and the customer it is billed to. The subscription implies the customer at
    # the processor, and both are sent because that is what the processor's own
    # `Invoice.upcoming` takes — the reference passes the same pair.
    #
    # What comes back is the processor's object, untouched. Every figure in it is
    # the processor's, including the two the caller derives the tax line from; a
    # tax figure invented here would be a figure this service did not keep, and
    # the disagreement would surface in a customer's invoice.
    def upcoming_invoice(processor_subscription_id:, processor_customer_id:)
      require_configured!

      perform(:upcoming_invoice, processor_subscription_id) do
        stripe.upcoming_invoice(
          customer: processor_customer_id,
          subscription: processor_subscription_id
        )
      end
    end

    # A self-serve portal URL: where a customer goes to update a card, change a
    # payment method or read an invoice. The processor owns that page — this
    # service has no payment-method form of its own, and one that stored a card
    # would be a card this service holds — so what goes out is the processor's
    # own customer id and where to come back to, and what comes back is the URL.
    #
    # `return_url` is the caller's and is required rather than defaulted: the
    # processor redirects there when the customer is done, and a default would be
    # a page this service chose for a caller it did not ask.
    def billing_portal_url(processor_customer_id:, return_url:)
      require_configured!

      # A customer with no id at the processor is not this service's
      # misconfiguration and not a `503`: it is a customer the processor does not
      # know, and the processor's own answer for one is a refusal. The guard is
      # deliberately absent — asking and being refused is the honest path, and
      # pre-empting it here would invent this service's own error for the
      # processor's fact.

      # The URL, and only the URL: `create_checkout_session` returns the whole
      # session and the caller reads `.id` and `.url` off it, so this is the same
      # shape — the client never invents a wrapper of its own, and the seam that
      # the specs inject returns the processor's own object.
      perform(:billing_portal, processor_customer_id) do
        stripe.billing_portal_url(
          customer: processor_customer_id,
          return_url: return_url
        ).url
      end
    end

    private
      # One translation of one refusal, for every call, so a caller handles
      # "Stripe refused" once. The processor's own message is kept verbatim: it is
      # the only description of the failure that came from the party that
      # produced it, and a paraphrase is a guess about what they meant.
      #
      # The cause is logged with the identifier that was refused, because the
      # message a caller receives will eventually reach an HTTP body, and a body
      # that carries a processor's internal error text is a leak. The log is
      # where it belongs.
      def perform(call, subject)
        yield
      rescue Stripe::StripeError => e
        Rails.logger.error("#{call} refused by the payment processor for #{subject}: #{e.class}: #{e.message}")

        raise RequestFailed, "the payment processor refused #{subject}: #{e.message}"
      end

      def stripe
        @api || real_api
      end

      # The gem. Loaded lazily and configured per request rather than by mutating
      # `Stripe.api_key`, which is global state: two clients with two keys in one
      # process would otherwise share whichever was set last.
      def real_api
        @real_api ||= GemStripeApi.new(@api_key)
      end

      def require_configured!
        return if @api_key.present?

        raise Unconfigured, "STRIPE_API_KEY is not configured, so no request can be made to the payment processor"
      end

    # The gem adapter. Its only jobs are to carry the key on the request and to
    # return the processor's own object untouched. The translation of a refusal
    # happens in `perform` above rather than here, so that a spec exercising the
    # fake exercises the same translation production does — a translation that
    # lived in the adapter would be untested by every spec that injects a fake,
    # which is every spec.
    #
    # The key goes on the request rather than onto `Stripe.api_key`, which is
    # global: two clients with two keys in one process would otherwise share
    # whichever was set last.
    class GemStripeApi
      def initialize(api_key)
        @api_key = api_key
      end

      def create_checkout_session(params)
        Stripe::Checkout::Session.create(params, api_key: @api_key)
      end

      def retrieve_subscription(id)
        Stripe::Subscription.retrieve(id, api_key: @api_key)
      end

      def update_subscription(id, params)
        Stripe::Subscription.update(id, params, api_key: @api_key)
      end

      def cancel_subscription(id, params)
        Stripe::Subscription.cancel(id, params, api_key: @api_key)
      end

      # `Invoice.upcoming` was REMOVED from the gem when Stripe replaced
      # `/v1/invoices/upcoming` with `/v1/invoices/create_preview`; the live
      # recording found the client calling a method that no longer exists, so
      # the whole upcoming-invoice route would have raised NoMethodError in
      # production. `create_preview` is the endpoint that replaced it, takes
      # the same `customer`/`subscription` pair, and answers the same invoice
      # shape the response builder reads.
      def upcoming_invoice(params)
        Stripe::Invoice.create_preview(params, api_key: @api_key)
      end

      def billing_portal_url(params)
        Stripe::BillingPortal::Session.create(params, api_key: @api_key)
      end
    end
  end
end
