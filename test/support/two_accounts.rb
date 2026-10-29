module TwoAccounts
  ACCOUNT_A = "11111111-1111-4111-8111-111111111111".freeze
  ACCOUNT_B = "22222222-2222-4222-8222-222222222222".freeze

  CUSTOMER_A = "cus_FAKEaccountAAAAAAAAAAAAAAAA".freeze
  CUSTOMER_B = "cus_FAKEaccountBBBBBBBBBBBBBBBB".freeze
  SUBSCRIPTION_A = "sub_FAKEaccountAAAAAAAAAAAAAAAA".freeze
  SUBSCRIPTION_B = "sub_FAKEaccountBBBBBBBBBBBBBBBB".freeze
  PRICE = "price_FAKEshaRedplanAaaaaaaaaaaaaa".freeze

  def account_a = ACCOUNT_A
  def account_b = ACCOUNT_B

  def create_account_customers
    @account_customers ||= {
      a: Customer.create!(owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe", processor_customer_id: CUSTOMER_A),
      b: Customer.create!(owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe", processor_customer_id: CUSTOMER_B)
    }
  end

  def customer_a = create_account_customers.fetch(:a)
  def customer_b = create_account_customers.fetch(:b)

  def shared_plan
    @shared_plan ||= Plan.create!(
      name: "Shared plan",
      slug: "shared-plan-#{SecureRandom.hex(6)}",
      price: Billing::Money.new(1_900, "USD"),
      interval: "month",
      processor_price_id: PRICE
    )
  end

  def create_account_subscriptions(status: "active")
    @account_subscriptions ||= begin
      plan = shared_plan
      {
        a: Subscription.create!(
              account_id: ACCOUNT_A, customer: customer_a, plan: plan,
              processor_subscription_id: SUBSCRIPTION_A, status: status
            ),
        b: Subscription.create!(
              account_id: ACCOUNT_B, customer: customer_b, plan: plan,
              processor_subscription_id: SUBSCRIPTION_B, status: status
            )
      }
    end
  end

  def subscription_a = create_account_subscriptions.fetch(:a)
  def subscription_b = create_account_subscriptions.fetch(:b)

  def fingerprint(records)
    Array(records).to_h do |record|
      record.reload
      columns = record.attributes.except("id", "created_at", "updated_at").sort.to_h

      [ record.id, Digest::SHA256.hexdigest(columns.inspect) ]
    end
  end

  def drifted_ids(before, records)
    Array(records).select { |record| fingerprint([ record ]).fetch(record.id) != before[record.id] }.map(&:id)
  end
end

module ActiveSupport
  class TestCase
    include TwoAccounts
  end
end
