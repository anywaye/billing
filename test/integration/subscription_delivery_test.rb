require "test_helper"

# The two properties this packet exists for, isolated from everything else.
#
# ## Replay
#
# Stripe retries on any non-2xx and promises nothing about ordering, so a delivery
# arriving twice is ordinary operation, not a bug. The cost of getting it wrong is
# a second envelope id for one fact, which a consumer deduplicating on that id
# cannot tell from new information.
#
# This is a *sweep*: the whole lifecycle, and at each step the event delivered a
# second time with the subscription, the outbox and the delivery row compared
# attribute for attribute afterwards. The per-fixture cases in
# test/services/subscriptions/lifecycle_test.rb are there to explain why; this one
# is here so that adding a fourth subscription event without a replay case is a
# failure rather than an omission nobody notices.
#
# ## The hand-off to courier
#
# Nothing here sends an email and nothing here calls courier. A transactional
# "your subscription started" is an event, and the outbox is how it gets there —
# which is the only arrangement that survives the publisher loop this repository
# does not have yet. These specs hold that the two events courier needs are
# published, declared, catalogued, and published *in the same transaction* as the
# state change that means there is something to send.
class SubscriptionDeliveryTest < ActiveSupport::TestCase
  # The lifecycle as it actually happens, in order. The first two are the setup
  # for the third and the fourth; the sweep walks the list and re-delivers each
  # entry in the state the walk has built up.
  SEQUENCE = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
  ].freeze

  # The three events the lifecycle can publish, written out rather than derived
  # from the class. A rename in the lifecycle then fails here instead of silently
  # changing what this file claims to be testing.
  SUBSCRIPTION_EVENTS = %w[
    billing.subscription.started
    billing.subscription.updated
    billing.subscription.canceled
  ].freeze

  # The two of those courier listens for. Also written out: courier is wired to
  # these strings, so a rename that only the code notices changes what a consumer
  # is subscribed to.
  COURIER_LISTENS_FOR = %w[
    billing.subscription.started
    billing.subscription.canceled
  ].freeze

  setup do
    travel_to(frozen_now)
    @customer = create_stripe_customer
    @plan = create_stripe_plan
  end

  test "the sweep covers every event the lifecycle acts on" do
    assert_equal Subscriptions::Lifecycle::TYPES.sort, SEQUENCE.sort
  end

  test "this file's list of published events is the lifecycle's" do
    published = Subscriptions::Lifecycle.constants
      .grep(/\A(STARTED|UPDATED|CANCELED)_EVENT\z/)
      .map { |name| Subscriptions::Lifecycle.const_get(name) }

    assert_equal SUBSCRIPTION_EVENTS.sort, published.sort
  end

  SEQUENCE.each_with_index do |fixture, index|
    test "delivering #{fixture} twice, in its real context, changes nothing" do
      # Everything before this event, so it arrives against the state it really
      # arrives against.
      SEQUENCE.first(index).each { |earlier| deliver(earlier) }

      deliver(fixture)
      subscription = Subscription.sole.attributes
      events = subscription_events
      delivery = ProcessorWebhook.find_by(stripe_event_id: event_id(fixture)).attributes

      deliver(fixture)

      assert_equal subscription, Subscription.sole.attributes
      assert_equal events, subscription_events
      assert_equal delivery, ProcessorWebhook.find_by(stripe_event_id: event_id(fixture)).attributes
    end

    test "delivering #{fixture} twice leaves one delivery row for it" do
      SEQUENCE.first(index).each { |earlier| deliver(earlier) }
      2.times { deliver(fixture) }

      assert_equal 1, ProcessorWebhook.where(stripe_event_id: event_id(fixture)).count
    end
  end

  test "the whole lifecycle delivers twice end to end and emits three events" do
    2.times { SEQUENCE.each { |fixture| deliver(fixture) } }

    assert_equal 3, ProcessorWebhook.count
    assert_equal [ "billing.subscription.started", "billing.subscription.updated", "billing.subscription.canceled" ],
      subscription_event_types
  end

  # The other form of replay, and the one a unique index cannot catch: the same
  # *fact* arriving under a fresh event id. A processor that re-emits after a
  # partial outage, or retries with a different signature, does this, and without
  # the no-change refusal it would produce a second `billing.subscription.started`
  # for a subscription that did not start twice.
  #
  # The same payload, deliberately: the committed `customer.subscription.updated`
  # fixture is a *different* fact from the `created` one — a different quantity
  # and a different cancellation intent — and is correctly published. Using it here
  # would have tested nothing.
  test "a fresh event id reporting the state we already hold emits nothing" do
    deliver("customer.subscription.created")
    before = subscription_events

    record = deliver("customer.subscription.created", event_id: "evt_the_same_fact_under_a_new_id")

    assert_equal before, subscription_events
    assert_equal "ignored:no_change_to_record", record.error
  end

  test "a fresh event id reporting the state we already hold changes no column" do
    deliver("customer.subscription.created")
    before = Subscription.sole.attributes

    deliver("customer.subscription.created", event_id: "evt_the_same_fact_under_a_new_id")

    assert_equal before, Subscription.sole.attributes
  end

  test "a genuinely different fact under a fresh id is published, not suppressed" do
    deliver("customer.subscription.created")
    before = subscription_event_types

    deliver("customer.subscription.updated", event_id: "evt_a_really_different_fact")

    assert_equal before + [ "billing.subscription.updated" ], subscription_event_types
  end

  # --- the hand-off -----------------------------------------------------------

  test "a signup publishes the event courier delivers the welcome mail from" do
    deliver("customer.subscription.created")

    assert_equal COURIER_LISTENS_FOR.first, subscription_event_types.sole
  end

  test "a cancellation publishes the event courier delivers the confirmation from" do
    deliver("customer.subscription.created")
    deliver("customer.subscription.deleted")

    assert_equal COURIER_LISTENS_FOR.last, subscription_event_types.last
  end

  test "both events courier needs are declared in the manifest" do
    manifest = YAML.load_file(Rails.root.join("cafaye.yml"))

    assert_empty COURIER_LISTENS_FOR - manifest.dig("exposes", "events")
  end

  test "both events courier needs are in the outbox's closed list" do
    assert_empty COURIER_LISTENS_FOR - OutboxEvent::TYPES
  end

  # The second environment-gated tier in this repository, and it was the worse
  # of the two because it did not say so.
  #
  # `core`'s catalog is read from a path derived from the checkout's own
  # directory, so this test passed on a developer machine that has the cafaye
  # repositories side by side and **errored on a CI runner**, which has one
  # checkout and no sibling:
  #
  #   Errno::ENOENT: No such file or directory @ rb_sysopen -
  #     <parent-of-checkout>/core/docs/event-naming.md
  #
  # The hardcoded path was the defect, not the failure. `outbox_envelope_
  # contract_test.rb` has read core through `CORE_PATH` since billing-02 and
  # falls back to the sibling directory for exactly this reason, so the seam
  # already existed and this file simply was not using it — which is how a
  # repository ends up with one core-reading tier that CI can run and another
  # that CI can only crash on.
  #
  # The skip is deliberate and narrow, and it is the shape PLAN §1 asks for: the
  # condition is stated in the test rather than implied by a missing file, and
  # CI sets `CORE_PATH` and **fails the build on any skipped test at all**, so
  # this line cannot be reached green in CI.
  #
  # Where core is, though, is no longer this file's own path arithmetic. It used
  # to spell `Rails.root.join("..", "core")` out here — the same sibling path
  # `outbox_envelope_contract_test.rb` used — which is right beside the main
  # checkout and resolves to nothing from a worktree. That is the BRK-4R2 hazard:
  # one skipped contract test silently, in every worktree, forever. The
  # resolution is now shared and walks the primary worktree through git, so the
  # two readers cannot drift and a worktree finds the same core its main
  # checkout does. The skip stays, for the case where core genuinely is not on
  # disk at all.
  test "both events courier needs have a row in core's catalog" do
    core_catalog = TestSupport::CoreLocation.path_for.join("docs", "event-naming.md")
    catalog = begin
      File.read(core_catalog)
    rescue Errno::ENOENT, Errno::ENOTDIR
      skip("core is not on disk at #{core_catalog}; set CORE_PATH to a core checkout")
    end
    billing_section = catalog[/^### billing.*?(?=^### |\z)/m].to_s

    COURIER_LISTENS_FOR.each do |event_type|
      assert_includes billing_section, "`#{event_type}`",
        "core's catalog has no row for #{event_type}, so nothing downstream could subscribe to it"
    end
  end

  # The hand-off is one-directional. billing publishes; courier subscribes. A
  # `consumes` entry would be a claim that this service listens to something, and
  # the only thing it would want to listen to is something identity emits.
  test "billing consumes no events, so it is not waiting on courier to do anything" do
    manifest = YAML.load_file(Rails.root.join("cafaye.yml"))

    assert_equal [], manifest.fetch("consumes")
  end

  # The whole point of the outbox: the event and the state change are one commit,
  # so courier can never be told about a signup whose row does not exist.
  test "the welcome-mail event and the subscription commit together" do
    with_refused_emission { deliver("customer.subscription.created") }

    assert_equal 0, Subscription.count
    assert_equal [], subscription_event_types
  end

  test "the confirmation event and the cancellation commit together" do
    deliver("customer.subscription.created")

    with_refused_emission { deliver("customer.subscription.deleted") }

    assert_equal "active", Subscription.sole.status
    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  private
    def subscription_events
      OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).map(&:attributes)
    end

    def subscription_event_types
      OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).pluck(:event_type)
    end

    def event_id(fixture)
      JSON.parse(stripe_fixture(fixture)).fetch("id")
    end

    # Each delivery gets its own instant.
    #
    # The suite's clock is frozen, so two outbox rows written by one test would
    # share a `created_at` and their order would fall to the uuid tiebreaker,
    # which is random — and "started, then updated, then canceled" is the fact under
    # test here. The event's own `time` is the processor's timestamp and is
    # unaffected, which is the point of it being the processor's.
    # The delivery's id travels **in** the body, because that is how it arrives:
    # `stripe_controller.rb` hands `Ingestion` `event_id: payload["id"]` and merges
    # the verified event's id over whatever the body claimed, so a delivery and the
    # payload that arrived with it can never disagree about which event this is.
    #
    # A helper that varied the delivery's id while leaving the body's id at the
    # fixture's was arranging a state Stripe never sends — and it **changed which
    # refusal fired**: `Subscriptions::Lifecycle`'s stale check compares the
    # processor's own `created` timestamp, so a re-delivery of the *same* fixture
    # under a new id was arriving with the same timestamp as the row's, and the
    # stale rule did not fire while `no_change_to_record` did. Once the id is moved
    # into the body, the case is honest: the assertion below is about a fresh id
    # reporting state already held, which is exactly the `no_change_to_record`
    # case and not the `stale_delivery` one.
    def deliver(fixture, event_id: nil)
      body = JSON.parse(stripe_fixture(fixture))
      resolved_id = event_id || body["id"]
      body = body.merge("id" => resolved_id)

      travel_to(frozen_now + (@deliveries = @deliveries.to_i + 1)) do
        Webhooks::Ingestion.new(
          processor: :stripe,
          event_id: resolved_id,
          type: body["type"],
          payload: body
        ).call
      end
    end

    # The emission is the last thing inside the transaction, so refusing it is the
    # closest reachable thing to a process dying between the row and the event.
    REFUSE_TO_EMIT = ->(_event) { raise ActiveRecord::StatementInvalid, "delivery lost while emitting" }

    def with_refused_emission
      OutboxEvent.set_callback(:create, :before, REFUSE_TO_EMIT)
      yield
    ensure
      OutboxEvent.skip_callback(:create, :before, REFUSE_TO_EMIT)
    end
end
