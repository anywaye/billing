require "test_helper"

# Three cross-tenant defects billing-12 found, and the three refusals that close
# them.
#
# ## What changed in this file, and why it is the same file
#
# billing-12 wrote these six tests to **document** F1, F2 and F3: each asserted
# that the defect was present, coupled itself to the thing that would remove it,
# and said in its own failure message that landing the fix should turn it red with
# an instruction to delete it. That was the right shape for a packet that reports
# findings, and it is why every one of them went red the moment
# `REPORT-billing-13-fixes`'s work landed.
#
# They are **replaced rather than deleted**, and they are the same tests: the same
# two accounts from `test/support/two_accounts.rb`, the same
# `customer.subscription.updated` delivery naming the other account's customer,
# the same `PATCH` on a caller's own row carrying a victim's `cus_`, the same pair
# of plans charging different amounts. **The setup is untouched. Only the
# assertion changed** — from "the row moved" to "the row did not move, and here is
# the refusal that stopped it".
#
# That is deliberate and it is the point. A test that proved the defect could not
# have been written from scratch after the fix without re-deciding what the
# defect was, and the risk of quietly proving something easier is exactly what a
# regression test is supposed to remove.
#
# The names change, because a test called "a delivery naming a different customer
# moves the subscription between accounts" that asserts it did **not** is a lie in
# the name, and the next person to read it would believe the first half. The
# `F1`/`F2`/`F3` prefix is kept, so `declared_finding_labels` below still derives
# the three findings from the file rather than from a constant.
#
# ## Where each fix actually lives, and what is therefore *not* here
#
#   * **F1** is a comparison in `Subscriptions::Lifecycle#apply`, raising
#     `Subscriptions::Refused` with the seventh reason, `account_mismatch`. The
#     delivery row carries `ignored:account_mismatch` and the endpoint answers
#     200 — a refusal is a decision, not an error. The 200 is asserted over the
#     HTTP edge in `test/integration/stripe_webhook_test.rb`, where the signing
#     path lives; here the assertions are about what happened to the row.
#   * **F2** and **F3** are unique indexes,
#     `customers_processor_customer_id_idx` and `plans_processor_price_id_idx`,
#     plus the model validations that turn a violation into a named 409.
#
# **The indexes are not proved here.** These tests run inside a transaction, and a
# `PG::UniqueViolation` aborts it — so a test that tried to show the *index*
# refusing would poison every assertion after it. That is what the two migration
# tests are for (`test/models/customer_processor_customer_id_migration_test.rb`,
# `test/models/plan_processor_price_id_migration_test.rb`), in files of their own
# because running a migration commits the enclosing transaction. This file proves
# the **API contract**: a caller who tries gets a refusal, and a refusal names the
# field.
class TenantCrossAccountFindingsTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  # --- F1: a delivery naming another account is refused -----------------------

  # **The refusal.** `Subscriptions::Lifecycle#apply` now compares the account the
  # delivery resolves to against the account already on the row, and refuses
  # before `assign_attributes` overwrites it.
  #
  # **Why the model could not catch it, which is the reason this was a finding.**
  # `Subscription#account_is_the_customers_owner` does compare an account against
  # a customer, and it is the only such check in the service. It passed: the new
  # account really does belong to the new customer, so the write was internally
  # consistent. What it cannot see is that the account **changed**, because the
  # rule it enforces is "a subscription's account is its customer's" and not "a
  # subscription's account does not move". The comparison had to be added to the
  # only writer, which is `Lifecycle`.
  #
  # **Asserted as the refusal and not only as an absence.** Four facts, and each
  # of them is a way the defect used to be observable: the row is byte-identical,
  # it still belongs to the account that paid, the delivery row records *which*
  # reason, and nothing was published. A guard that stopped the write but still
  # published an update would pass the first two and fail the fourth.
  test "F1: a delivery naming a different customer is refused and the subscription does not move" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: SUBSCRIPTION_A, customer: customer_a, event_id: "evt_FAKEfind1")
    row = Subscription.find_by!(processor_subscription_id: SUBSCRIPTION_A)
    assert_equal ACCOUNT_A, row.account_id, "the first delivery should have billed account A"

    before = fingerprint([ row ])
    # The events that legitimately exist before the refused delivery. Compared
    # rather than asserted empty, because the **first** delivery is supposed to
    # have published `billing.subscription.started` for this very row: a test that
    # asserted "no events" would be asserting that the first delivery did nothing,
    # which is a different bug and not this one.
    events_before = subscription_events_for(row)

    # The second delivery names account B's customer for the subscription id that
    # account A holds. A processor does not do this; a processor *dashboard* does,
    # and so does the F2 collision below, which is what made this reachable
    # through this service's own surface.
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

    # And nothing new was published. The reassignment used to be announced as an
    # update carrying the new account, so a consumer counting plan changes, or
    # reading one account's billing timeline, was told this was always the
    # arrangement. Silence is the whole of the fix here: a refusal that published
    # an event would still be a reassignment to anybody downstream.
    assert_equal events_before, subscription_events_for(row),
      "the refused delivery published an event. A refusal that emits is not a refusal; the " \
      "lifecycle has to raise before it writes an outbox row."
  end

  # The half that makes F1 a *money* defect rather than a bookkeeping one, and it
  # is worth stating what changed: before the fix, the subscription did not stop
  # working — it started working for somebody else. The row stayed `live`, so
  # `grants_entitlements?` stayed true, which is the point. **Entitlements are
  # decided by status and a reassignment did not change the status**, so a consumer
  # asking "is this subscription active?" saw an active subscription for an account
  # that never paid for one.
  #
  # Now the row is still live — which is right, nobody canceled it — and it is live
  # **for the account that bought it**. Those two facts are the same assertion from
  # either side of the fix, which is why the comparisons below are unchanged and
  # only their direction is.
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

    # Still live, still granting — now for the right account. The finding was about
    # *which account* a live subscription belongs to, so the row's status is
    # asserted unchanged; if this is false something else wrote the status and the
    # refusal is not the only thing that changed.
    assert row.grants_entitlements?,
      "the subscription stopped granting. The finding is about *which account* a live " \
      "subscription belongs to, not about whether it is live; if this is false the row's " \
      "status changed and this test needs rewriting."
  end

  # --- F2: one Stripe customer id, one customer row ---------------------------

  # **The refusal.** `customers_processor_customer_id_idx` is unique over the
  # non-null values, and `Customer` carries a matching validation so the collision
  # is a named answer rather than a raw index violation. `Lifecycle#customer`
  # resolves a delivery with `find_by` and no `ORDER BY`, so two rows on one `cus_`
  # made *which account a delivery is billed to* undecided by the data.
  #
  # The index itself is proved in
  # `test/models/customer_processor_customer_id_migration_test.rb`; what is proved
  # here is that a caller gets a refusal that names the field.
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

  # F2 was reachable through this service's own surface, and that is what
  # separated it from a theoretical one: `CustomerUpdate` closes `owner` and
  # `processor` — the columns the existing `(owner_type, owner_id, processor)`
  # index is built on — and permits `processor_customer_id`, making that one column
  # the whole attack surface. A `PATCH` on a caller's **own** row copied a
  # victim's `cus_` onto it.
  #
  # The answer is a 409 and the caller's row is untouched. Both halves matter: a
  # 409 with the write half-applied would be a different bug, and a silent 200
  # that ignored the field would leave the client believing it had moved.
  test "F2: a client can no longer point its own customer row at another account's Stripe customer id" do
    victim = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe",
      processor_customer_id: "cus_FAKEvictimBBBBBBBBBBBBB"
    )
    attacker = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe",
      processor_customer_id: "cus_FAKEattackerAAAAAAAAA"
    )
    # **Acting as A.** `/v1` is scoped by the token's `account_id` since billing-21, so
    # without this the `PATCH` would be a 404 — the scoping, not the unique index — and
    # this test would pass while proving nothing about F2. F2's own refusal is a 409, and
    # `cross_account_web_test.rb` is where the 404 boundary is proved.
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

  # The flip of the test that used to assert the ambiguity. billing-12 pinned the
  # two candidates and that `find_by` returns one of them, and **deliberately did
  # not assert which** — asserting it would be a test of PostgreSQL's mood, and
  # the ambiguity *was* the finding.
  #
  # There is no longer anything to be ambiguous about, so the strongest available
  # statement is the one that could not be made before: **the resolution is
  # single-valued**. The same `find_by`, the same pair of accounts, and it now has
  # one answer that the data decides — because the second claimant cannot be
  # written. The equality at the end is the assertion the old test declined to
  # make, and the index is what makes it safe to make.
  test "F2: the resolution is no longer ambiguous, because the second claimant cannot be written" do
    shared = "cus_FAKEambiguousBBBBBBBBBBBBB"
    written = { "a" => contested_customer(ACCOUNT_A, shared), "b" => contested_customer(ACCOUNT_B, shared) }

    claimants = Customer.where(processor_customer_id: shared).pluck(:owner_id)
    resolved = Customer.find_by(processor_customer_id: shared)

    # Exactly one of the two writes was accepted. Which one is the data's business
    # and this test does not say — the old version of this test declined to, and
    # was right to: the point is that there is one answer, not which it is.
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

  # --- F3: one Stripe price id, one plan --------------------------------------

  # **The refusal.** The same shape one table over. A plan is catalogue and the
  # catalogue is shared on purpose, so this one is a correctness defect rather than
  # a tenancy one — and the consequence is worse than a lookup landing on the
  # wrong row. The two plans charge **different amounts**, so a subscription
  # billed against whichever one claimed the id is billed at a price this service
  # never agreed to with the customer, and `billing.subscription.started` carries
  # that plan's `currency` and nothing about the one that was intended. The wrong
  # amount is not only charged but published.
  #
  # The index is proved in
  # `test/models/plan_processor_price_id_migration_test.rb`; the amount difference
  # is asserted here so the reason this is a money defect stays visible rather than
  # becoming "a lookup might be wrong".
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

  # --- what these three are, now that they are fixed -------------------------

  # The three findings are about the **delivery** path, where this service resolves
  # a row from an identifier a third party controls. They are not about the
  # database's account-scoped constraints, and the two must not be confused:
  # `(account_id, plan_id)` and `(owner_type, owner_id, processor)` both hold
  # today, and `cross_account_delivery_test.rb` proves each one behaviourally.
  #
  # The shape of this assertion is deliberately the **inverse** of the one it
  # replaces. It used to pin that two resolution keys were ambiguous — a count that
  # had to drop to zero — which is a tripwire for the fix. It now pins that **no**
  # resolution key is ambiguous, which is a tripwire for the *unfixing*: drop
  # `customers_processor_customer_id_idx` and the count goes back up and this fails
  # by name. A guard that can only be tripped in one direction is a test of a
  # moment rather than of a property.
  test "meta: no resolution key is ambiguous, and the two indexes are what say so" do
    attempt_ambiguous_resolution_keys

    assert_empty ambiguous_resolution_keys,
      "a delivery can again resolve a row ambiguously. The unique indexes over " \
      "`customers.processor_customer_id` and `plans.processor_price_id` are the fix; one of " \
      "them has been dropped, and `REPORT-billing-13-fixes` has to be corrected."

    # The indexes are asserted **here** rather than in the two migration tests, and
    # the placement is the point.
    #
    # The migration tests have to *rebuild* the index — they roll it back and up to
    # prove the `down` works — so any assertion in them about the index's shape
    # would be reading an index the file had just created itself. A mutation
    # proved it: with a non-unique index in place, `test "the index is unique"`
    # inside the migration file still passed, because whichever test ran first had
    # already restored the right one and the file's teardown repaired the table
    # before the assertion read it. **This file observes and never repairs**, so
    # what it reads is what the database actually has.
    assert_equal [ "customers_processor_customer_id_idx", "plans_processor_price_id_idx" ],
      unique_processor_id_indexes, "the uniqueness that closes F2 and F3 is not on the table"
  end

  # The findings are **fixed** in this packet, and this asserts that in the
  # direction that matters: that the file still names the same three findings, that
  # each has its reproductions, and that the fix for F1 is on the class rather than
  # somewhere a reader would not look.
  #
  # billing-12's version of this test asserted they were *not* fixed, so that a fix
  # landing quietly would leave the report describing a defect that no longer
  # exists. That concern still holds and the assertion is still here — the label set
  # and the test count are pinned, so a finding quietly dropped from this file
  # fails rather than passing unnoticed.
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
    # Both collisions, **attempted**. A helper that reads the database for
    # ambiguity cannot arrange it any more — that was always the awkward part of
    # asserting a finding, and it is why this now attempts the writes and lets the
    # refusals happen. Nothing is rescued: a collision that is *accepted* is the
    # failure, and the assertions above read the result.
    def attempt_ambiguous_resolution_keys
      [ ACCOUNT_A, ACCOUNT_B ].each { |account| contested_customer(account, "cus_FAKEambiguousBBBBBBBBBBBBB") }
      create_stripe_plan(processor_price_id: "price_FAKEambiguousAAAAAAAAA", price: Billing::Money.new(1_900, "USD"))
      contested_plan("price_FAKEambiguousAAAAAAAAA", Billing::Money.new(49_000, "USD"))
    end

    # A customer row **aimed at** an id another row already holds, with the write
    # attempted.
    #
    # `create!` would raise before the assertions ran, and a test that has to
    # rescue its own setup to check that the setup was refused is a test whose
    # failure is an exception rather than a message — so the record is saved
    # rather than saved-and-bang, and the caller reads `persisted?` and `errors`.
    # The distinction matters: `refute_predicate record, :persisted?` is a claim
    # about the database, and a raised `RecordInvalid` would have proved nothing
    # about whether the row is there.
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

    # The tests whose name names a finding. Counted so the report's "three findings,
    # six reproductions" is a fact about this file rather than a number in prose that
    # no test holds.
    def declared_finding_tests
      self.class.public_instance_methods(false).grep(/\Atest_F\d:/).sort
    end

    # The distinct findings, from the same names. F1 and F2 each take more than one
    # test, so counting tests and counting findings are two different numbers and
    # conflating them is how a report ends up claiming three reproductions of two
    # findings.
    def declared_finding_labels
      declared_finding_tests.map { |method| method.to_s[/\Atest_(F\d):/, 1] }.uniq.sort
    end

    # The columns a delivery resolves a tenant row by, keyed by table — a column
    # that currently has more than one claimant for some value.
    #
    # The `group … having` is the honest way to ask it, and it is worth saying why
    # this is not just "count the rows": the question is whether *any* value is
    # claimed twice, which is a question about the whole column and not about one
    # fixture's id. With the unique indexes in place this is provably empty — which
    # is exactly why the indexes are also asserted by name in the test above.
    def ambiguous_resolution_keys
      ambiguous = {}
      ambiguous["customers"] = 2 if Customer.where.not(processor_customer_id: nil).group(:processor_customer_id).having("count(*) > 1").any?
      ambiguous["plans"] = 2 if Plan.where.not(processor_price_id: nil).group(:processor_price_id).having("count(*) > 1").any?
      ambiguous
    end

    # The unique indexes, read from the database rather than from `schema.rb` — the
    # same reason the matrix test derives its enumeration: a test that reads the
    # committed schema file is a test of a comment.
    #
    # **`unique` is part of the filter on purpose.** A plain index over the column
    # would be invisible here, so a drop to a non-unique index — the one mutation
    # that would leave the rule documented and unenforced — fails this assertion by
    # name rather than passing because the index is technically there.
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

    # One delivery, built from the committed fixture so the shape is one the
    # processor actually sends, with the four fields a subscription is resolved by
    # moved onto the rows under test.
    #
    # The event's `id` is merged into the body, which is what
    # `Webhooks::StripeController` does in production: the delivery's id and the
    # payload that arrived with it are one value. A helper that varied one without
    # the other would arrange a state Stripe never sends, and the outbox's unique
    # index over `processor_event_id` would then turn a correct test into a
    # duplicate-delivery refusal.
    #
    # The updated event is one second later because the lifecycle refuses a
    # delivery that is not strictly newer than the one that last wrote the row
    # (`stale_delivery`). A second delivery at the *same* processor timestamp is
    # not stale — epoch seconds are coarse — but it would then be refused as
    # `no_change_to_record` if the two deliveries agreed about everything, and the
    # finding here is a delivery that disagrees. It is also *not* the ordering that
    # lets F1's guard fire first: the account comparison happens after the machine
    # and the stale check, so a test that relied on their order would be testing
    # the order rather than the account.
    def deliver_subscription_event(type, subscription_id:, customer:, event_id:)
      body = JSON.parse(stripe_fixture(type == "customer.subscription.created" ? "customer.subscription.created" : "customer.subscription.updated"))
      object = body.dig("data", "object")

      body["id"] = event_id
      object["id"] = subscription_id
      object["customer"] = customer.processor_customer_id
      object["metadata"] = { "cafaye_customer_id" => customer.id }
      object.dig("items", "data", 0, "price")["id"] = shared_plan.processor_price_id
      object["plan"]["id"] = shared_plan.processor_price_id

      Webhooks::Ingestion.new(processor: :stripe, event_id: event_id, type: body["type"], payload: body).call
    end

    # The subscription's own events, by **subject** — the row's own uuid, which is
    # what `Lifecycle#apply` publishes under. A `find_by(event_type:)` alone would
    # match the `billing.subscription.started` the *first* delivery legitimately
    # published and report the refusal as having emitted something.
    def subscription_events_for(subscription)
      OutboxEvent.where(subject: subscription.id).pluck(:event_type)
    end
end
