require "test_helper"

# The normalizer. It is the only place that knows what a Stripe object looks
# like, and the only place a cafaye id would be substituted if billing lands one.
# What comes out is a processor-independent hash, so nothing downstream — and no
# consumer of the emitted events — has to parse Stripe's shape again.
class Webhooks::StripeEventsTest < ActiveSupport::TestCase
  test "a subscription creation normalizes to the subscription's own fields" do
    data = normalize("customer.subscription.created")

    assert_equal "subscription", data.fetch("kind")
    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", data.fetch("subscription_id")
    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", data.fetch("customer_id")
    assert_equal "active", data.fetch("status")
    assert_equal 2, data.fetch("quantity")
    assert_equal "price_1PZQaBcDeFgHiJkLmNoPqR2", data.fetch("price_id")
  end

  test "a normalized subscription carries its period as RFC3339 UTC, not an epoch" do
    data = normalize("customer.subscription.created")

    assert_equal "2026-09-30T04:00:00Z", data.fetch("current_period_start")
    assert_equal "2026-10-30T04:00:00Z", data.fetch("current_period_end")
  end

  test "a normalized subscription carries its amount as integer minor units" do
    data = normalize("customer.subscription.created")

    assert_equal({ "amount_minor" => 2900, "currency" => "USD" }, data.fetch("unit_amount"))
  end

  test "a normalized subscription records the processor and its event id" do
    data = normalize("customer.subscription.created")

    assert_equal "stripe", data.fetch("processor")
    assert_equal "evt_1PZQaBcDeFgHiJkLmNoPqR1", data.fetch("processor_event_id")
  end

  test "a subscription update reports the new quantity and the cancellation intent" do
    data = normalize("customer.subscription.updated")

    assert_equal 3, data.fetch("quantity")
    assert_equal true, data.fetch("cancel_at_period_end")
    assert_equal "active", data.fetch("status")
  end

  test "a subscription deletion reports the cancellation time" do
    data = normalize("customer.subscription.deleted")

    assert_equal "canceled", data.fetch("status")
    assert_equal "2026-11-14T04:00:00Z", data.fetch("canceled_at")
  end

  test "a paid invoice normalizes to a payment" do
    data = normalize("invoice.paid")

    assert_equal "payment", data.fetch("kind")
    assert_equal "in_1PZQaBcDeFgHiJkLmNoPqR3", data.fetch("invoice_id")
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqR4", data.fetch("payment_intent_id")
    assert_equal true, data.fetch("paid")
  end

  test "a paid invoice normalizes the settled amount as integer minor units" do
    data = normalize("invoice.paid")

    assert_equal({ "amount_minor" => 8700, "currency" => "USD" }, data.fetch("amount"))
  end

  test "a failed invoice normalizes to a payment that did not settle" do
    data = normalize("invoice.payment_failed")

    assert_equal "payment", data.fetch("kind")
    assert_equal false, data.fetch("paid")
    assert_equal({ "amount_minor" => 2900, "currency" => "USD" }, data.fetch("amount"))
  end

  test "a failed invoice records the attempt count and when the next attempt is due" do
    data = normalize("invoice.payment_failed")

    assert_equal 1, data.fetch("attempt_count")
    assert_equal "2026-10-09T04:00:00Z", data.fetch("next_payment_attempt")
  end

  test "a paid invoice records no next attempt, because there is nothing to retry" do
    data = normalize("invoice.paid")

    assert_equal 1, data.fetch("attempt_count")
    assert_nil data.fetch("next_payment_attempt")
  end

  test "a one-time checkout session normalizes to a payment" do
    data = normalize("checkout.session.completed.payment")

    assert_equal "payment", data.fetch("kind")
    assert_equal "cs_test_b1PZQaBcDeFgHiJkLmNoP", data.fetch("checkout_session_id")
    assert_equal "pi_3PZQaBcDeFgHiJkLmNoPqRd", data.fetch("payment_intent_id")
    assert_equal({ "amount_minor" => 1500, "currency" => "USD" }, data.fetch("amount"))
  end

  test "a one-time checkout session carries the reference the caller put on it" do
    data = normalize("checkout.session.completed.payment")

    assert_equal "acc_01J9Z8RR7B2QK3M4N5P6Q7R8S9T", data.fetch("client_reference_id")
  end

  # The recipient fact. A consumer of these events — courier, for a receipt or a
  # payment-failure warning — has no billing client and no billing tables, so the
  # address has to be on the envelope. The field is named `email` because that is
  # what identity's events call it (`identity.session.revoked`,
  # `identity.user.created`): one fleet, one field name for the address a
  # consumer cannot look up.
  #
  # The lookup is the one query the payment path makes that the normalizer does
  # not: one indexed read on `customers.processor_customer_id`, which is unique
  # (billing-13). It is asserted here as the builder's contract — the field is
  # present exactly when a cafaye customer with an address on file is the one the
  # payment is about — and the end-to-end path through `Ingestion` is the
  # contract test's business.
  test "a payment payload carries the billing email of the customer it is about" do
    Customer.create!(
      owner_type: "Account",
      owner_id: "11111111-1111-4111-8111-111111111111",
      processor: "stripe",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0",
      email: "billing@example.com"
    )

    data = Webhooks::StripeEvents.with_recipient(normalize("invoice.paid"))

    assert_equal "billing@example.com", data.fetch("email")
  end

  test "a payment payload for a customer with no address on file carries no email" do
    Customer.create!(
      owner_type: "Account",
      owner_id: "11111111-1111-4111-8111-111111111111",
      processor: "stripe",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0"
    )

    data = Webhooks::StripeEvents.with_recipient(normalize("invoice.paid"))

    refute_includes data.keys, "email"
  end

  test "a payment payload for a customer this service has never seen carries no email" do
    data = Webhooks::StripeEvents.with_recipient(normalize("invoice.paid"))

    refute_includes data.keys, "email"
  end

  # The failed-payment path resolves the customer the same way the settled one
  # does: a warning about a decline is mailed to the same address a receipt is,
  # and the two events are built by the same builder.
  test "a failed payment's payload carries the same customer's email" do
    Customer.create!(
      owner_type: "Account",
      owner_id: "11111111-1111-4111-8111-111111111111",
      processor: "stripe",
      processor_customer_id: "cus_R1pQKz9xLp2mN4vB6yH8jL0",
      email: "billing@example.com"
    )

    data = Webhooks::StripeEvents.with_recipient(normalize("invoice.payment_failed"))

    assert_equal "billing@example.com", data.fetch("email")
  end

  # Stripe sends both of these for one signup: the Checkout session, then the
  # subscription's own lifecycle events. Emitting from both would state one fact
  # twice, under two different envelope ids.
  test "a subscription checkout session is deliberately ignored, not emitted" do
    error = assert_raises(Webhooks::Ignored) { normalize("checkout.session.completed") }

    assert_equal "subscription_mode_is_restated_by_the_subscription_lifecycle", error.reason
  end

  test "the ignore reason names the fact that supersedes it" do
    error = assert_raises(Webhooks::Ignored) { normalize("checkout.session.completed") }

    assert_includes error.reason, "subscription"
  end

  # Every event type this build can emit is a member of the closed list the
  # outbox validates against. A mapping added without a matching row there would
  # park every delivery as a failure at runtime, so the two are asserted to be
  # the same set here rather than discovered by Stripe.
  MAPPED_TO = {
    "customer.subscription.created" => "billing.subscription.started",
    "customer.subscription.updated" => "billing.subscription.updated",
    "customer.subscription.deleted" => "billing.subscription.canceled",
    "invoice.paid" => "billing.payment.succeeded",
    "invoice.payment_failed" => "billing.payment.failed",
    "checkout.session.completed.payment" => "billing.payment.succeeded"
  }.freeze

  MAPPED_TO.each do |fixture, event_type|
    test "the #{fixture} mapping produces #{event_type}, which the outbox accepts" do
      payload = JSON.parse(stripe_fixture(fixture))
      data = Webhooks::StripeEvents.normalize(payload)

      # The processor's own `type` from the body, not the fixture's name: the two
      # Checkout fixtures share one `type` and differ only in the mode inside
      # them, and it is the body's type that `Ingestion` routes on.
      assert_equal event_type, Webhooks::StripeEvents.event_type_for(payload.fetch("type"), data)
      assert_includes OutboxEvent::TYPES, event_type
    end
  end

  test "the handler registry and the type table are the same list" do
    assert_equal(
      (Webhooks::StripeEvents::EVENT_TYPES.keys + [ Webhooks::StripeEvents::CHECKOUT_TYPE ]).sort,
      Webhooks::StripeEvents::NORMALIZERS.keys.sort
    )
  end

  # A mapping for a type the outbox does not list would park every delivery as a
  # `failed:` row and answer 200, which is a silent outage discovered by Stripe's
  # dashboard rather than by this service's tests.
  test "every type the mapping can produce is one this service has declared" do
    produced = Webhooks::StripeEvents::NORMALIZERS.keys.filter_map do |type|
      next if type == Webhooks::StripeEvents::CHECKOUT_TYPE

      Webhooks::StripeEvents::EVENT_TYPES[type]
    end

    assert_empty produced - OutboxEvent::TYPES
  end

  # The processor's own ids are load-bearing until cafaye's land, so a shape
  # change that drops one has to be a failing test, not a surprise in a
  # consumer's inbox.
  #
  # Two keys were added in billing-04 and each is load-bearing. `cafaye_customer_id`
  # is the link back to a cafaye customer, carried in the subscription's metadata
  # because a customer created through `/v1` has a null `processor_customer_id` until
  # its first subscription names one. `trial_ends_at` is the shape core's payload
  # schema asks for: a date-time, or null while trialing with no end date.
  #
  # The processor's own `created` is deliberately *not* here. `Webhooks::Ingestion`
  # computes it once and hands the same instant to the handler and to the outbox row,
  # so a second copy in the normalized hash would be a second reading of one field.
  SUBSCRIPTION_KEYS = %w[
    kind processor processor_event_id subscription_id customer_id cafaye_customer_id status
    quantity price_id unit_amount current_period_start current_period_end cancel_at_period_end
    canceled_at trial trial_ends_at
  ]

  KNOWN_KEYS = {
    "customer.subscription.created" => SUBSCRIPTION_KEYS,
    "customer.subscription.updated" => SUBSCRIPTION_KEYS,
    "customer.subscription.deleted" => SUBSCRIPTION_KEYS,
    "invoice.paid" => %w[
      kind processor processor_event_id customer_id subscription_id invoice_id payment_intent_id
      paid amount attempt_count next_payment_attempt
    ],
    "invoice.payment_failed" => %w[
      kind processor processor_event_id customer_id subscription_id invoice_id payment_intent_id
      paid amount attempt_count next_payment_attempt
    ],
    "checkout.session.completed.payment" => %w[
      kind processor processor_event_id customer_id checkout_session_id payment_intent_id
      client_reference_id paid amount
    ]
  }.freeze

  KNOWN_KEYS.each do |type, keys|
    test "the normalized #{type} hash has exactly the documented keys" do
      assert_equal keys.sort, normalize(type).keys.sort
    end
  end

  test "a payload with no subscription on the invoice still normalizes" do
    payload = JSON.parse(stripe_fixture("invoice.paid"))
    payload["data"]["object"].delete("subscription")

    data = Webhooks::StripeEvents.normalize(payload)

    assert_nil data["subscription_id"]
    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", data["customer_id"]
  end

  test "an unknown type has no normalizer" do
    assert_nil Webhooks::StripeEvents.normalize(JSON.parse(stripe_fixture("charge.succeeded")))
  end

  test "a payload missing the object raises rather than inventing defaults" do
    assert_raises(Webhooks::StripeEvents::UnprocessableEvent) do
      Webhooks::StripeEvents.normalize({ "id" => "evt_1", "type" => "invoice.paid", "data" => {} })
    end
  end

  test "a non-integer amount is refused instead of rounded" do
    payload = JSON.parse(stripe_fixture("invoice.paid"))
    payload["data"]["object"]["amount_paid"] = "8700.5"

    assert_raises(Money::InvalidAmountError) do
      Webhooks::StripeEvents.normalize(payload)
    end
  end

  private
    def normalize(type)
      Webhooks::StripeEvents.normalize(JSON.parse(stripe_fixture(type)))
    end
end
