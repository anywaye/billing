module StripeSubscriptionFixtures
  PROCESSOR_CUSTOMER_ID = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze
  PROCESSOR_PRICE_ID = "price_1PZQaBcDeFgHiJkLmNoPqR2".freeze

  ACCOUNT_ID = TestSupport::TestIdentity::Account

  ADDITIONAL_CUSTOMER_IDS = %w[
    cus_FAKEmemberBBBBBBBBBBBBBB
    cus_FAKEteammateBBBBBBBBBBBBB
    cus_FAKEguestBBBBBBBBBBBBBBB
  ].freeze

  ADDITIONAL_PRICE_IDS = %w[
    price_FAKEteamplanBBBBBBBBB
    price_FAKElateralplanBBBBBBB
    price_FAKEcheaperplanBBBBBBB
    price_FAKEyearlyplanBBBBBBBB
  ].freeze

  def create_stripe_customer(account_id: ACCOUNT_ID, owner_type: "Account", processor_customer_id: nil)
    Customer.create!(
      owner_type: owner_type,
      owner_id: owner_type == "Account" ? account_id : SecureRandom.uuid,
      processor: "stripe",
      processor_customer_id: processor_customer_id || next_processor_customer_id
    )
  end

  def create_stripe_plan(price: Billing::Money.new(1900, "USD"), interval: "month", processor_price_id: nil, slug: nil, name: nil)
    index = next_index

    Plan.create!(
      name: name || "Pro #{index}",
      slug: slug || "pro-#{index}",
      price: price,
      interval: interval,
      processor_price_id: processor_price_id || next_processor_price_id
    )
  end

  private
    def next_index
      @stripe_rows = @stripe_rows.to_i + 1
    end

    def next_processor_customer_id
      available = [ PROCESSOR_CUSTOMER_ID, *ADDITIONAL_CUSTOMER_IDS ]
      taken = Customer.where.not(processor_customer_id: nil).pluck(:processor_customer_id)

      pick_next(available, taken, "customer")
    end

    def next_processor_price_id
      available = [ PROCESSOR_PRICE_ID, *ADDITIONAL_PRICE_IDS ]
      taken = Plan.where.not(processor_price_id: nil).pluck(:processor_price_id)

      pick_next(available, taken, "price")
    end

    def pick_next(available, taken, kind)
      id = available.find { |candidate| !taken.include?(candidate) }
      raise "no unused processor #{kind} id left; add one to StripeSubscriptionFixtures" if id.nil?

      id
    end
end

module ActiveSupport
  class TestCase
    include StripeSubscriptionFixtures
  end
end
