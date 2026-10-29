class FakeStripeAPI
  CheckoutSession = Data.define(:id, :url)
  Subscription = Data.define(:id, :status, :cancel_at_period_end)

  KNOWN_PRICES = %w[
    price_1PZQaBcDeFgHiJkLmNoPqR2
    price_new
    price_FAKEteamplanBBBBBBBBB
    price_FAKElateralplanBBBBBBB
    price_FAKEcheaperplanBBBBBBB
    price_FAKEyearlyplanBBBBBBBB
  ].freeze
  KNOWN_SUBSCRIPTIONS = %w[sub_1PZQaBcDeFgHiJkLmNoPqR1].freeze

  class StripeRefused < Stripe::StripeError; end

  attr_reader :requests

  def initialize
    @requests = []
    @sessions = 0
  end

  def create_checkout_session(params)
    @requests << params

    refuse_unknown_price(params[:line_items].first.fetch(:price))

    @sessions += 1
    id = format("cs_test_%014d", @sessions)
    CheckoutSession.new(id, "https://checkout.stripe.test/c/pay/#{id}")
  end

  RetrievedItem = Data.define(:id)
  RetrievedItems = Data.define(:data)
  RetrievedSubscription = Data.define(:id, :items)

  def retrieve_subscription(id)
    @requests << { id: id, call: :retrieve }

    refuse_unknown_subscription(id)

    RetrievedSubscription.new(id, RetrievedItems.new([ RetrievedItem.new("si_FAKE#{id.delete_prefix("sub_")}") ]))
  end

  def update_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_price(params[:items].first.fetch(:price)) if params[:items]
    refuse_unknown_subscription(id)

    Subscription.new(id, "active", params[:cancel_at_period_end] == true)
  end

  def cancel_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_subscription(id)

    Subscription.new(id, "canceled", false)
  end

  InvoiceLine = Data.define(:description, :period, :quantity, :pricing, :amount, :currency)
  InvoicePeriod = Data.define(:start, :end)
  InvoicePricing = Data.define(:unit_amount_decimal)
  UpcomingInvoice = Data.define(:period_end, :currency, :lines, :subtotal, :total_excluding_tax, :total)

  def upcoming_invoice(params)
    @requests << params

    refuse_unknown_subscription(params[:subscription])

    period_start = Time.now.to_i
    period_end = period_start + 30 * 24 * 60 * 60
    amount = 1900

    UpcomingInvoice.new(
      period_end: period_end,
      currency: "usd",
      lines: [
        InvoiceLine.new(
          description: "Pro monthly",
          period: InvoicePeriod.new(period_start, period_end),
          quantity: 1,
          pricing: InvoicePricing.new(BigDecimal(amount.to_s)),
          amount: amount,
          currency: "usd"
        )
      ],
      subtotal: amount,
      total_excluding_tax: amount,
      total: amount + 247
    )
  end

  PortalSession = Data.define(:url)

  def billing_portal_url(params)
    @requests << params

    refuse_unknown_customer(params[:customer])

    PortalSession.new("https://billing.stripe.test/session/pcss_00000000000001")
  end

  private
    def refuse_unknown_customer(customer)
      return if customer.present?

      raise StripeRefused, "No such customer: #{customer}"
    end

    def refuse_unknown_price(price)
      return if KNOWN_PRICES.include?(price)

      raise StripeRefused, "No such price: #{price}"
    end

    FAKE_DOOR_PREFIX = "sub_FAKE"

    def refuse_unknown_subscription(id)
      return if KNOWN_SUBSCRIPTIONS.include?(id)
      return if id.start_with?(FAKE_DOOR_PREFIX)

      raise StripeRefused, "No such subscription: #{id}"
    end
end
