require "test_helper"

class TenantCrossAccountFindingsTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end


  test "F1: a delivery naming a different customer is refused and the subscription does not move" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: SUBSCRIPTION_A, customer: customer_a, event_id: "evt_FAKEfind1")
    row = Subscription.find_by!(processor_subscription_id: SUBSCRIPTION_A)
    assert_equal ACCOUNT_A, row.account_id, "the first delivery should have billed account A"

    before = fingerprint([ row ])
    events_before = subscription_events_for(row)

    record = deliver_subscription_updated(subscription_id: SUBSCRIPTION_A, customer: customer_b, event_id: "evt_FAKEfind2")

    assert_equal "ignored:account_mismatch", record.error,
      "the delivery row must record the refusal and say which one. A different reason means " \
      "the delivery was refused for something other than the account, and F1's guard is not " \
      "what stopped it — check the ordering against `stale_delivery` and the state machine."

    row.reload
    assert_empty drifted_ids(before, [ row ]),
      "the row changed, so the subscription moved between accounts. The guard in " \
      "`Lifecycle#apply` compares the resolved account with the one already on the row and " \
      "refuses; nothing may be written before that comparison."
    assert_equal ACCOUNT_A, row.account_id,
      "the subscription no longer belongs to the account that paid for it"
    assert_equal customer_a.id, row.customer_id,
      "the subscription now points at the customer the second delivery named"

    assert_equal events_before, subscription_events_for(row),
      "the refused delivery published an event. A refusal that emits is not a refusal; the " \
      "lifecycle has to raise before it writes an outbox row."
  end

  test "F1: the account that paid still holds the live subscription, and the one that named it holds nothing" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: SUBSCRIPTION_A, customer: customer_a, event_id: "evt_FAKEfind3")
    row = Subscription.find_by!(processor_subscription_id: SUBSCRIPTION_A)
    assert_equal [ row.id ], Subscription.where(account_id: ACCOUNT_A).pluck(:id)

    deliver_subscription_updated(subscription_id: SUBSCRIPTION_A, customer: customer_b, event_id: "evt_FAKEfind4")

    row.reload
    assert_equal [ row.id ], Subscription.where(account_id: ACCOUNT_A).pluck(:id),
      "the account that paid no longer holds the subscription it paid for"
    assert_empty Subscription.where(account_id: ACCOUNT_B),
      "account B holds a subscription a delivery named it on. B never bought one, and B is " \
      "not going to be billed for one; the guard in `Lifecycle#apply` refuses the delivery " \
      "before the account is written."

    assert row.grants_entitlements?,
      "the subscription stopped granting. The finding is about *which account* a live " \
      "subscription belongs to, not about whether it is live; if this is false the row's " \
      "status changed and this test needs rewriting."
  end


  test "F2: two accounts can no longer hold customer rows that answer to one Stripe customer id" do
    shared = "cus_FAKEcontestedBBBBBBBBBBBB"

    first = Customer.create!(owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe", processor_customer_id: shared)
    second = contested_customer(ACCOUNT_B, shared)

    assert_equal 1, Customer.where(processor_customer_id: shared).count,
      "two accounts hold the id again. `customers_processor_customer_id_idx` is unique over " \
      "the non-null values and `Customer` validates it; a second row means one of the two is gone."
    assert_equal ACCOUNT_A, first.owner_id, "the first row must have been written, or this proves nothing"
    refute_predicate second, :persisted?
    assert second.errors.of_kind?(:processor_customer_id, :taken),
      "the refusal must name `processor_customer_id` and say it is taken, so the 409 tells a " \
      "client which field collided. Got: #{second.errors.full_messages.join('; ')}"
    assert_equal [ ACCOUNT_A, ACCOUNT_B ], [ first.owner_id, ACCOUNT_B ].sort,
      "the two rows must have been aimed at different accounts, or the collision proves nothing"
  end

  test "F2: a client can no longer point its own customer row at another account's Stripe customer id" do
    victim = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe",
      processor_customer_id: "cus_FAKEvictimBBBBBBBBBBBBB"
    )
    attacker = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe",
      processor_customer_id: "cus_FAKEattackerAAAAAAAAA"
    )
    acts_as(ACCOUNT_A)
    before = fingerprint([ attacker ])

    patch "/v1/customers/#{attacker.id}", params: { processor_customer_id: victim.processor_customer_id }, as: :json

    assert_response :conflict,
      "the PATCH was not refused. `processor_customer_id` is unique, so claiming another " \
      "account's `cus_` is a 409 — the request was well-formed and it collides."
    assert_equal 1, Customer.where(processor_customer_id: victim.processor_customer_id).count,
      "two rows answer to the victim's `cus_`. A validation that refuses a `save` is not a " \
      "lock; the index is what holds under concurrency, and both are required."
    assert_empty drifted_ids(before, [ attacker ]),
      "the caller's own row changed even though the request was refused. A 409 that half-wrote " \
      "the row would leave the caller holding an id it was not given."
    assert_equal "cus_FAKEattackerAAAAAAAAA", attacker.reload.processor_customer_id,
      "the refused field was written anyway"
  end

  test "F2: the resolution is no longer ambiguous, because the second claimant cannot be written" do
    shared = "cus_FAKEambiguousBBBBBBBBBBBBB"
    written = { "a" => contested_customer(ACCOUNT_A, shared), "b" => contested_customer(ACCOUNT_B, shared) }

    claimants = Customer.where(processor_customer_id: shared).pluck(:owner_id)
    resolved = Customer.find_by(processor_customer_id: shared)

    assert_equal 1, written.values.count(&:persisted?),
      "the two writes did not resolve to one winner and one refusal, so the collision is not " \
      "what it was arranged to be. Exactly one row may claim a `cus_`."
    assert_equal 1, claimants.size,
      "#{claimants.size} rows answer to the id, so the resolution is still a coin toss. The " \
      "index is unique over the non-null values; only one of these two rows can exist."
    assert_predicate resolved, :present?, "`find_by` returned nothing, which is `unknown_customer` and not this test"
    assert_equal claimants.sole, resolved.owner_id,
      "`find_by` returned a row that is not the only claimant, which would be a third defect"
  end


  test "F3: two plans can no longer claim one Stripe price id" do
    shared = "price_FAKEcontestedAAAAAAAAAA"

    first = create_stripe_plan(processor_price_id: shared, price: Billing::Money.new(1_900, "USD"))
    second = contested_plan(shared, Billing::Money.new(49_000, "USD"))

    refute_equal first.amount_cents, second.amount_cents,
      "the two plans must charge different amounts, or a collision would be a cosmetic " \
      "lookup problem rather than a pricing one"
    assert_equal 1, Plan.where(processor_price_id: shared).count,
      "two plans share the price id again. `plans_processor_price_id_idx` is unique over the " \
      "non-null values and `Plan` validates it; a second row means one of the two is gone."
    assert_equal [ first.id ], Plan.where(processor_price_id: shared).pluck(:id),
      "the plan that claimed the id changed, so the collision resolved to the wrong one"
    refute_predicate second, :persisted?
    assert second.errors.of_kind?(:processor_price_id, :taken),
      "the refusal must name `processor_price_id` and say it is taken, so the 409 tells a " \
      "client which field collided. Got: #{second.errors.full_messages.join('; ')}"
  end


  test "meta: no resolution key is ambiguous, and the two indexes are what say so" do
    attempt_ambiguous_resolution_keys

    assert_empty ambiguous_resolution_keys,
      "a delivery can again resolve a row ambiguously. The unique indexes over " \
      "`customers.processor_customer_id` and `plans.processor_price_id` are the fix; one of " \
      "them has been dropped, and `REPORT-billing-13-fixes` has to be corrected."

    assert_equal [ "customers_processor_customer_id_idx", "plans_processor_price_id_idx" ],
      unique_processor_id_indexes, "the uniqueness that closes F2 and F3 is not on the table"
  end

  test "meta: the three findings are still named, still reproduced, and F1's guard is on the lifecycle" do
    attempt_ambiguous_resolution_keys

    assert_equal %w[F1 F2 F3], declared_finding_labels,
      "the set of findings changed. A new label is a fourth finding to report; a missing one " \
      "means a finding was dropped from this file, and `REPORT-billing-13-fixes` must say so."
    assert_equal 6, declared_finding_tests.size,
      "the number of tests reproducing a finding changed. F1 and F2 each take more than one " \
      "because each needed the consequence proven as well as the mechanism."
    assert_equal "account_mismatch", Subscriptions::Lifecycle::ACCOUNT_REASON,
      "the refusal reason F1 records on the delivery row changed. It is the seventh reason and " \
      "part of this service's contract — it is what a human reads on `processor_webhooks.error`."
  end

  private
    def attempt_ambiguous_resolution_keys
      [ ACCOUNT_A, ACCOUNT_B ].each { |account| contested_customer(account, "cus_FAKEambiguousBBBBBBBBBBBBB") }
      create_stripe_plan(processor_price_id: "price_FAKEambiguousAAAAAAAAA", price: Billing::Money.new(1_900, "USD"))
      contested_plan("price_FAKEambiguousAAAAAAAAA", Billing::Money.new(49_000, "USD"))
    end

    def contested_customer(account_id, processor_customer_id)
      Customer.new(
        owner_type: "Account", owner_id: account_id, processor: "stripe",
        processor_customer_id: processor_customer_id
      ).tap(&:save)
    end

    def contested_plan(processor_price_id, price)
      @contested_plans = @contested_plans.to_i + 1

      Plan.new(
        name: "Contested #{@contested_plans}",
        slug: "contested-#{@contested_plans}",
        price: price,
        interval: "month",
        processor_price_id: processor_price_id
      ).tap(&:save)
    end

    def declared_finding_tests
      self.class.public_instance_methods(false).grep(/\Atest_F\d:/).sort
    end

    def declared_finding_labels
      declared_finding_tests.map { |method| method.to_s[/\Atest_(F\d):/, 1] }.uniq.sort
    end

    def ambiguous_resolution_keys
      ambiguous = {}
      ambiguous["customers"] = 2 if Customer.where.not(processor_customer_id: nil).group(:processor_customer_id).having("count(*) > 1").any?
      ambiguous["plans"] = 2 if Plan.where.not(processor_price_id: nil).group(:processor_price_id).having("count(*) > 1").any?
      ambiguous
    end

    def unique_processor_id_indexes
      %w[customers plans].flat_map { |table|
        ActiveRecord::Base.connection.indexes(table)
          .select { |index| index.unique && index.columns.size == 1 && index.columns.first.start_with?("processor_") }
          .map(&:name)
      }.sort
    end

    def account_scoped_queries
      Dir[Rails.root.join("app/**/*.rb")].sum { |path|
        File.read(path).scan(/(?:where|find|find_by|find_by!)\(.*?account_id:/).size
      }
    end

    def deliver_subscription_created(subscription_id:, customer:, event_id:)
      deliver_subscription_event("customer.subscription.created", subscription_id: subscription_id, customer: customer, event_id: event_id)
    end

    def deliver_subscription_updated(subscription_id:, customer:, event_id:)
      deliver_subscription_event("customer.subscription.updated", subscription_id: subscription_id, customer: customer, event_id: event_id)
    end

    def deliver_subscription_event(type, subscription_id:, customer:, event_id:)
      body = JSON.parse(stripe_fixture(type == "customer.subscription.created" ? "customer.subscription.created" : "customer.subscription.updated"))
      object = body.dig("data", "object")

      body["id"] = event_id
      object["id"] = subscription_id
      object["customer"] = customer.processor_customer_id
      object["metadata"] = { "anywaye_customer_id" => customer.id }
      object.dig("items", "data", 0, "price")["id"] = shared_plan.processor_price_id
      object["plan"]["id"] = shared_plan.processor_price_id

      Webhooks::Ingestion.new(processor: :stripe, event_id: event_id, type: body["type"], payload: body).call
    end

    def subscription_events_for(subscription)
      OutboxEvent.where(subject: subscription.id).pluck(:event_type)
    end
end
