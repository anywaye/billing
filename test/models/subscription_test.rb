require "test_helper"

# The subscription's own row: what it holds, what it refuses, and the one
# uniqueness rule that is about a *set* of statuses rather than a single value.
#
# The transitions a subscription may make are not tested here. They live in
# `Subscriptions::StateMachine` and are tested as a table there, because a
# state machine tested one method at a time is a set of conditionals with tests
# attached.
class SubscriptionTest < ActiveSupport::TestCase
  setup do
    travel_to(frozen_now)
  end

  test "a subscription holds the plan, the customer and the account being billed" do
    subscription = build_subscription

    assert_equal plan, subscription.plan
    assert_equal customer, subscription.customer
    assert_equal customer.owner_id, subscription.account_id
  end

  test "the processor's subscription id is unique" do
    create_subscription
    duplicate = build_subscription

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:processor_subscription_id], "has already been taken"
  end

  test "the database refuses a duplicate processor subscription id even if the model did not" do
    create_subscription
    rogue = build_subscription(processor_subscription_id: "sub_rogue")

    assert_raises(ActiveRecord::RecordNotUnique) do
      rogue.save!(validate: false)
    end
  end

  STATUS_CASES = {
    "a trialing subscription" => { status: "trialing", live: true, terminal: false },
    "an active subscription" => { status: "active", live: true, terminal: false },
    "a past-due subscription" => { status: "past_due", live: true, terminal: false },
    "an unpaid subscription" => { status: "unpaid", live: true, terminal: false },
    "a canceled subscription" => { status: "canceled", live: false, terminal: true }
  }.freeze

  STATUS_CASES.each do |name, expected|
    test "#{name} is stored and reported by its own predicates" do
      subscription = create_subscription(status: expected[:status])

      assert_equal expected[:status], subscription.status
      assert_equal expected[:live], subscription.live?
      assert_equal expected[:terminal], subscription.canceled?
    end
  end

  test "a status outside the set is a validation failure naming the field" do
    subscription = build_subscription(status: "incomplete")

    assert_not subscription.valid?
    assert_includes subscription.errors.attribute_names, :status
  end

  # A Rails `enum` would raise ArgumentError on `incomplete` the moment it was
  # assigned, which at an HTTP boundary is a 500 for something the client got
  # wrong. The database still refuses it, so a validation is not the only wall.
  test "the database refuses a status outside the set" do
    build_subscription
    rogue = build_subscription(status: "incomplete", processor_subscription_id: "sub_rogue")

    assert_raises(ActiveRecord::StatementInvalid) do
      rogue.save!(validate: false)
    end
  end

  # `account_id` is identity's uuid, and the column is `uuid`, so Active Record
  # casts "acc_…" to nil before a validation sees it. There is deliberately no
  # shape validation here: it would be unreachable code that read as if it were
  # doing something. What has to hold is that a subscription cannot exist without
  # an account, and the column agrees.
  test "a subscription requires an account" do
    subscription = build_subscription(account_id: nil)

    assert_not subscription.valid?
    assert_includes subscription.errors.attribute_names, :account_id
  end

  test "the database refuses a null account" do
    subscription = build_subscription
    subscription.account_id = nil

    assert_raises(ActiveRecord::StatementInvalid) do
      subscription.save!(validate: false)
    end
  end

  # The migration inlines the statuses rather than reading them from the model, so
  # that it still means what it meant the day it ran. The cost of inlining is that a
  # status added to the model and not to the constraint is invisible, so it is
  # checked here: the constraint is read out of the database and compared with the
  # model's set.
  test "the database accepts every status the model stores" do
    definition = check_constraint_definition("subscriptions_status_known")

    Subscription::STATUSES.each do |status|
      assert_includes definition, "'#{status}'",
        "#{status} is a status this service stores but the CHECK constraint does not name"
    end
  end

  test "the database's constraint names no status the model does not" do
    definition = check_constraint_definition("subscriptions_status_known")

    assert_empty definition.scan(/'([a-z_]+)'/).flatten - Subscription::STATUSES,
      "the CHECK constraint names a status the model does not, so the model would refuse a row the database allows"
  end

  # The live-uniqueness index, read out of the database, against the model's own
  # statement about what "live" is. `catalog.pg_constraint` rather than the
  # migration's source, because the migration is a comment about the past and this
  # is the database.
  test "the live index excludes exactly the terminal statuses" do
    predicate = index_predicate("subscriptions_live_account_plan_idx")

    Subscription::TERMINAL_STATUSES.each do |status|
      assert_includes predicate, "'#{status}'"
    end
  end

  test "the account must be the customer's own account" do
    subscription = build_subscription(account_id: create_account)

    assert_not subscription.valid?
    assert_includes subscription.errors[:account_id], "is not this customer's account"
  end

  # Which account a user belongs to is identity's fact, and no event carrying it
  # is in this build's `consumes`. So a user-owned customer cannot be billed, and
  # the refusal says so rather than inventing an account.
  test "a customer owned by a user cannot hold a subscription" do
    user_owned = Customer.create!(owner_type: "User", owner_id: SecureRandom.uuid, processor: "stripe")
    subscription = build_subscription(customer: user_owned, account_id: user_owned.owner_id)

    assert_not subscription.valid?
    assert_includes subscription.errors[:customer], "is not an account, and a subscription is billed to an account"
  end

  test "the customer and the plan are required" do
    subscription = Subscription.new(
      account_id: SecureRandom.uuid,
      processor_subscription_id: "sub_missing",
      status: "active"
    )

    assert_not subscription.valid?
    assert_includes subscription.errors.attribute_names, :customer
    assert_includes subscription.errors.attribute_names, :plan
  end

  test "it serializes to the wire shape" do
    subscription = create_subscription(
      current_period_start: Time.utc(2026, 9, 30, 4, 0, 0),
      current_period_end: Time.utc(2026, 10, 30, 4, 0, 0)
    )

    assert_equal(
      {
        "id" => subscription.id,
        "account_id" => customer.owner_id,
        "plan_id" => plan.id,
        "plan_slug" => plan.slug,
        "customer_id" => customer.id,
        "processor_subscription_id" => "sub_1PZQaBcDeFgHiJkLmNoPqR1",
        "status" => "active",
        "current_period_start" => "2026-09-30T04:00:00Z",
        "current_period_end" => "2026-10-30T04:00:00Z",
        "cancel_at_period_end" => false,
        "canceled_at" => nil,
        "created_at" => "2026-09-30T12:00:00Z",
        "updated_at" => "2026-09-30T12:00:00Z"
      },
      subscription.as_json
    )
  end

  test "it carries no processor bookkeeping on the wire" do
    subscription = create_subscription(last_processor_event_at: Time.utc(2026, 9, 30, 4, 0, 0))

    refute_includes subscription.as_json.keys, "last_processor_event_at"
  end

  # The index that says "one live subscription per (account, plan)" is a
  # statement about a set of statuses, so the way to test it is behaviourally:
  # insert two rows with the same pair and see whether the database objects.
  # Comparing the index's predicate to a string in the model would prove the two
  # texts agree, which is not the same fact.
  UNIQUENESS_CASES = {
    "two active subscriptions" => { first: "active", second: "active", collides: true },
    "an active one and a trialing one" => { first: "active", second: "trialing", collides: true },
    "an active one and a past-due one" => { first: "active", second: "past_due", collides: true },
    "an active one and an unpaid one" => { first: "active", second: "unpaid", collides: true },
    "an active one and a canceled one" => { first: "active", second: "canceled", collides: false },
    "a canceled one and a live one" => { first: "canceled", second: "active", collides: false },
    "two canceled ones" => { first: "canceled", second: "canceled", collides: false }
  }.freeze

  UNIQUENESS_CASES.each do |name, expected|
    test "#{name} share one (account, plan) key" do
      create_subscription(status: expected[:first], processor_subscription_id: "sub_first")

      assert_equal expected[:collides], collides?(expected[:second])
    end
  end

  test "a customer can return to a plan they have canceled before" do
    first = create_subscription(status: "active", processor_subscription_id: "sub_first")
    first.update!(status: "canceled")

    returned = create_subscription(status: "active", processor_subscription_id: "sub_second")

    assert_predicate returned, :persisted?
  end

  test "a second account may hold the same plan at the same time" do
    create_subscription(status: "active", processor_subscription_id: "sub_first")
    other_customer = create_customer(account_id: create_account)

    subscription = create_subscription(
      customer: other_customer,
      account_id: other_customer.owner_id,
      processor_subscription_id: "sub_second",
      status: "active"
    )

    assert_predicate subscription, :persisted?
  end

  test "one account may hold two live subscriptions to two different plans" do
    create_subscription(status: "active", processor_subscription_id: "sub_first")
    other_plan = Plan.create!(name: "Team monthly", slug: "team-monthly", price: Billing::Money.new(4900, "USD"), interval: "month")

    subscription = create_subscription(
      plan: other_plan,
      processor_subscription_id: "sub_second",
      status: "active"
    )

    assert_predicate subscription, :persisted?
  end

  test "the processor's id is what resolves a row" do
    create_subscription

    assert_equal Subscription.sole, Subscription.find_by(processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1")
  end

  # One account holds one *live* subscription per plan, so each live status gets
  # its own plan: the point here is the predicate, not the index, which the
  # uniqueness cases above already cover.
  test "it grants entitlements while it is live" do
    Subscription::LIVE_STATUSES.each do |status|
      subscription = create_subscription(
        status: status,
        processor_subscription_id: "sub_#{status}",
        plan: new_plan
      )

      assert_predicate subscription, :grants_entitlements?
    end
  end

  test "it grants nothing once it is canceled" do
    assert_not create_subscription(status: "canceled").grants_entitlements?
  end

  # A subscription is never a place an event is written from. Its status is the
  # processor's statement and nothing else, so there is no `after_create` or
  # `after_update` here that could emit one. The lifecycle is the only writer,
  # and it emits.
  test "writing a subscription emits no event" do
    customer
    plan

    assert_no_difference "OutboxEvent.count" do
      create_subscription
    end
  end

  test "updating a subscription emits no event" do
    subscription = create_subscription
    plan

    assert_no_difference "OutboxEvent.count" do
      subscription.update!(cancel_at_period_end: true)
    end
  end

  private
    def connection
      ActiveRecord::Base.lease_connection
    end

    def check_constraint_definition(name)
      connection.select_value(<<~SQL).to_s
        select pg_get_constraintdef(oid) from pg_constraint where conname = '#{name}'
      SQL
    end

    def index_predicate(name)
      connection.select_value(<<~SQL).to_s
        select pg_get_expr(indpred, indrelid) from pg_index where indexrelid = '#{name}'::regclass
      SQL
    end

    def collides?(status)
      build_subscription(status: status, processor_subscription_id: "sub_collision").save
      false
    rescue ActiveRecord::RecordNotUnique
      true
    end

    def build_subscription(overrides = {})
      Subscription.new(
        {
          account_id: customer.owner_id,
          customer: customer,
          plan: plan,
          processor_subscription_id: "sub_1PZQaBcDeFgHiJkLmNoPqR1",
          status: "active"
        }.merge(overrides)
      )
    end

    def create_subscription(overrides = {})
      record = build_subscription(overrides)
      record.save!
      record
    end

    def customer
      @customer ||= create_customer
    end

    # A **distinct** `cus_` per customer, and not because these two helpers
    # wanted variety: `customers_processor_customer_id_idx` is unique, so the two
    # of them sharing one id was an F2 collision this file was accidentally
    # arranging. `test "a second account may hold the same plan at the same time"`
    # builds two customers, and the second was refused for holding an id the first
    # already had. `build_customer` never saves, so it needs no counter and takes
    # the same first id for a row that is only going to be validated.
    def create_customer(account_id: nil)
      @customer_count = @customer_count.to_i + 1

      Customer.create!(
        owner_type: "Account",
        owner_id: account_id || create_account,
        processor: "stripe",
        processor_customer_id: next_processor_customer_id
      )
    end

    def build_customer
      Customer.new(
        owner_type: "Account",
        owner_id: create_account,
        processor: "stripe",
        processor_customer_id: next_processor_customer_id
      )
    end

    def next_processor_customer_id
      [ "cus_FIRST", *StripeSubscriptionFixtures::ADDITIONAL_CUSTOMER_IDS ][@customer_count - 1] ||
        raise("no unused processor customer id left in this file")
    end

    def create_account
      @accounts ||= []
      @accounts << SecureRandom.uuid
      @accounts.last
    end

    def plan
      @plan ||= new_plan
    end

    def new_plan
      @plan_count = @plan_count.to_i + 1
      Plan.create!(
        name: "Pro #{@plan_count}",
        slug: "pro-#{@plan_count}",
        price: Billing::Money.new(1900, "USD"),
        interval: "month"
      )
    end
end
