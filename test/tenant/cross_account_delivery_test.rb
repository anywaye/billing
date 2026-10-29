require "test_helper"

class TenantCrossAccountDeliveryTest < ActiveSupport::TestCase
  OPERATION_KINDS = %w[read list write update delete].freeze

  class << self
    def declared_test_methods
      public_instance_methods(false).grep(/\Atest_/).sort
    end

    def negative_test_methods
      declared_test_methods.reject { |method| method.to_s.start_with?("test_meta:") }
    end

    def bookkeeping_test_methods
      declared_test_methods.select { |method| method.to_s.start_with?("test_meta:") }
    end

    def negative_test_kinds
      negative_test_methods.filter_map { |method| method.to_s[/\Atest_([a-z_]+):/, 1] }
    end
  end

  setup do
    travel_to(frozen_now)
  end


  test "read: one account cannot acquire another account's customer row" do
    create_account_customers

    duplicate = Customer.new(
      owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe",
      processor_customer_id: "cus_FAKEthirdpartyCCCCCCCCCCCC"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:processor], "has already been taken"
    assert_equal 2, Customer.where(owner_type: "Account").count,
      "the pair must be two rows, or the comparison above proves nothing"
  end

  test "read: two accounts may hold live subscriptions on the same plan" do
    create_account_subscriptions

    assert_equal [ shared_plan.id ], subscription_a.plan_id == shared_plan.id ? [ subscription_a.plan_id ] : []
    assert_equal shared_plan.id, subscription_b.plan_id
    assert_equal 2, Subscription.live.count,
      "two accounts on one plan is the legitimate case the index must not refuse"
  end

  test "update: an account cannot hold two live subscriptions on one plan" do
    create_account_subscriptions

    second = Subscription.new(
      account_id: ACCOUNT_A, customer: customer_a, plan: shared_plan,
      processor_subscription_id: "sub_FAKEsameplananewAAAAAAA", status: "active"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { second.save! }
    assert_equal 2, Subscription.live.count, "the refused write must not have left a row"
  end

  test "update: the account boundary is scoped to live rows, so a cancelled account may return" do
    create_account_subscriptions
    subscription_a.update!(status: "canceled")

    returning = Subscription.new(
      account_id: ACCOUNT_A, customer: customer_a, plan: shared_plan,
      processor_subscription_id: "sub_FAKEReturningAAAAAAA", status: "active"
    )

    assert returning.save, "a cancelled subscription must not block the account from resubscribing: #{returning.errors.full_messages.inspect}"
  end

  test "update: a subscription cannot be written against an account that is not its customer's" do
    create_account_customers
    plan = shared_plan

    mismatched = Subscription.new(
      account_id: ACCOUNT_B, customer: customer_a, plan: plan,
      processor_subscription_id: "sub_FAKEmismatchedAAAAAAA", status: "active"
    )

    assert_not mismatched.valid?
    assert_includes mismatched.errors[:account_id], "is not this customer's account"
    assert_equal 0, Subscription.where(account_id: ACCOUNT_B, customer_id: customer_a.id).count,
      "the refused write must not have left a row"
  end

  test "update: a user-owned customer cannot be turned into an account's subscription" do
    user_owned = Customer.create!(
      owner_type: "User", owner_id: "33333333-3333-4333-8333-333333333333", processor: "stripe"
    )

    row = Subscription.new(
      account_id: ACCOUNT_A, customer: user_owned, plan: shared_plan,
      processor_subscription_id: "sub_FAKEuserownedAAAAAAAAA", status: "active"
    )

    assert_not row.valid?
    assert_includes row.errors[:customer], "is not an account, and a subscription is billed to an account"
  end

  test "write: the event a customer's creation publishes names that customer's own account" do
    create_account_customers

    event = OutboxEvent.where(subject: customer_a.id).sole

    assert_equal "billing.customer.created", event.event_type
    assert_equal ACCOUNT_A, event.data.dig("owner", "id")
    assert_equal "Account", event.data.dig("owner", "type")
    refute_includes event.data.to_json, ACCOUNT_B,
      "an event about account A must not carry account B anywhere in its payload"
  end

  test "write: the event a delivery publishes names the account it resolved" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: "sub_FAKEdeliveryAAAAAAAAA", customer: customer_a, event_id: "evt_FAKEdelivery1")

    row = Subscription.find_by!(processor_subscription_id: "sub_FAKEdeliveryAAAAAAAAA")
    event = OutboxEvent.find_by!(subject: row.id)

    assert_equal "billing.subscription.started", event.event_type
    assert_equal ACCOUNT_A, event.data.fetch("account_id")
    assert_equal customer_a.id, row.customer_id
    refute_includes event.data.to_json, ACCOUNT_B,
      "an event resolved to account A must not carry account B anywhere in its payload"
  end

  test "list: nothing in this service reads an outbox row back by account" do
    create_account_customers

    assert_equal 0, Rails.application.routes.routes.count { |route|
      route.path.spec.to_s.include?("outbox")
    }, "a route that exposes the outbox is a new account-scoped read and is not in the entry point matrix"

    refute_includes OutboxEvent.column_names, "account_id"
    assert_equal 1, OutboxEvent.where(subject: customer_a.id).count
  end


  test "list: a cursor carries a position and an identifier, and no account's billing data" do
    create_account_subscriptions

    decoded = JSON.parse(Base64.urlsafe_decode64(mint_cursor_for(subscription_a)))

    assert_equal %w[at id], decoded.keys.sort
    assert_equal subscription_a.id, decoded.fetch("id")
    assert_kind_of String, decoded.fetch("at")
    assert_equal 2, decoded.size, "a cursor with a third key is carrying something it has no business carrying"
  end

  test "list: a cursor is a keyset, and a keyset cannot widen the query it pages" do
    create_account_subscriptions

    source = Rails.root.join("app/controllers/concerns/cursor_paging.rb").read
    keyset = source[/def apply_cursor\b.*?\n    end/m]

    assert_includes keyset, "scope.where("
    assert_includes keyset, "(created_at, id)"
    refute_match(/\b(?:Customer|Plan|Subscription)\b/, keyset,
      "`apply_cursor` now names a model. A cursor is client-supplied and unsigned, so a " \
      "model name here would be a caller choosing what the query is about.")
  end


  test "delete: there is nothing to scope, because this service destroys nothing" do
    create_account_subscriptions

    assert_equal 0, destroyable_entry_points,
      "app/ grew a destroy. That is a delete, it needs an account scope, and the " \
      "entry point matrix needs a row for it."
    assert_equal 2, Subscription.count, "both accounts' rows are present and intact"

    assert_equal %w[trialing active past_due], Subscription::ACTIONABLE_STATUSES
  end


  test "meta: this file's negative tests are counted from their names, by operation" do
    assert_equal({ "read" => 2, "list" => 3, "write" => 2, "update" => 4, "delete" => 1 },
                 breakdown(self.class.negative_test_kinds))
  end

  test "meta: every negative test names the operation it covers" do
    unlabelled = self.class.negative_test_methods.reject { |method| method.to_s.match?(/\Atest_[a-z_]+:/) }

    assert_empty unlabelled.map { |method| method.to_s.delete_prefix("test_") },
      "these tests carry no \"<kind>:\" prefix, so the breakdown above does not count " \
      "them. Name them \"read: …\", \"list: …\", \"write: …\", \"update: …\" or \"delete: …\", " \
      "or \"meta: …\" if the test is about this file rather than about an account."
  end

  test "meta: every operation a negative test names is one of the five kinds" do
    unknown = self.class.negative_test_kinds.reject { |kind| OPERATION_KINDS.include?(kind) }

    assert_empty unknown,
      "these negative tests name an operation outside #{OPERATION_KINDS.inspect}: #{unknown.inspect}"
  end

  test "meta: the six tests about this file are the ones excluded from its coverage" do
    assert_equal 6, self.class.bookkeeping_test_methods.size
    assert_equal 12, self.class.negative_test_methods.size
    assert_equal self.class.declared_test_methods.size,
                 self.class.bookkeeping_test_methods.size + self.class.negative_test_methods.size
  end

  test "meta: delete is one negative test over zero entry points, and the reason is recorded" do
    assert_equal 0, destroyable_entry_points
    assert_equal 1, breakdown(self.class.negative_test_kinds).fetch("delete"),
      "the delete negative test is the one that says there is nothing to delete. If a " \
      "second appeared, this service has grown a destroy and the entry point matrix " \
      "needs a row for it."
  end

  test "meta: the operation vocabulary is the five kinds, in the order the report quotes them" do
    assert_equal %w[read list write update delete], OPERATION_KINDS
  end

  private
    def breakdown(kinds)
      OPERATION_KINDS.index_with { |kind| kinds.count(kind) }
    end

    def destroyable_entry_points
      Dir[Rails.root.join("app/**/*.rb")].sum { |path|
        File.read(path).scan(/\b(?:destroy|destroy_all|delete_all)\b/).size
      }
    end

    def deliver_subscription_created(subscription_id:, customer:, event_id:)
      body = JSON.parse(stripe_fixture("customer.subscription.created"))
      object = body.dig("data", "object")

      body["id"] = event_id
      object["id"] = subscription_id
      object["customer"] = customer.processor_customer_id
      object["metadata"] = { "anywaye_customer_id" => customer.id }
      object.dig("items", "data", 0, "price")["id"] = shared_plan.processor_price_id
      object["plan"]["id"] = shared_plan.processor_price_id

      Webhooks::Ingestion.new(processor: :stripe, event_id: event_id, type: body["type"], payload: body).call
    end

    def mint_cursor_for(record)
      Base64.urlsafe_encode64(
        { "at" => record.created_at.utc.iso8601(6), "id" => record.id }.to_json,
        padding: false
      )
    end
end
