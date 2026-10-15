# A stand-in for the Stripe API, for the specs that have to make a request.
#
# It records what it was asked and returns a fixture of the processor's answer.
# The point is what the tests assert on: the *request*. A checkout URL and a
# subscription's existence both come from Stripe, so a test that invented them
# would be asserting its own invention; a test that records the request is
# asserting the thing this service is responsible for.
#
# It refuses exactly what Stripe refuses, so the error paths are real requests
# rather than a stubbed exception: a plan price that does not exist, and a
# subscription that does not.
class FakeStripeAPI
  # The processor's own ids, in the shapes the fixtures use.
  CheckoutSession = Data.define(:id, :url)
  Subscription = Data.define(:id, :status, :cancel_at_period_end)

  # Prices and subscriptions this fake knows about. Everything else is refused,
  # which is what makes "the processor said no" a thing the specs can arrange.
  #
  # The price list has to contain every price `StripeSubscriptionFixtures` hands
  # a plan, or a spec that puts a second plan on sale gets a processor refusal
  # where it meant a successful one. That is a second literal kept in step with
  # the first, and `test/support/fixture_processor_ids_test.rb` asserts the two
  # agree — the fake loads before the fixtures module, so the agreement cannot be
  # structural and is checked instead.
  KNOWN_PRICES = %w[
    price_1PZQaBcDeFgHiJkLmNoPqR2
    price_new
    price_FAKEteamplanBBBBBBBBB
    price_FAKElateralplanBBBBBBB
    price_FAKEcheaperplanBBBBBBB
    price_FAKEyearlyplanBBBBBBBB
  ].freeze
  KNOWN_SUBSCRIPTIONS = %w[sub_1PZQaBcDeFgHiJkLmNoPqR1].freeze

  # A refusal, in the processor's own vocabulary.
  #
  # The client rescues `Stripe::StripeError` because that is what the gem raises,
  # so the fake raises a subclass of it. That keeps the translation under test
  # honest: if the fake invented its own error class, the specs would pass while
  # the rescue clause in production went untouched.
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

  def update_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_price(params[:items].first) if params[:items]
    refuse_unknown_subscription(id)

    Subscription.new(id, "active", params[:cancel_at_period_end] == true)
  end

  def cancel_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_subscription(id)

    Subscription.new(id, "canceled", false)
  end

  # The projection: the processor's own answer for `Invoice.upcoming`, recorded
  # like every other request and answered with a fixture the same shape the
  # gem returns. A subscription the fake does not know about is refused,
  # because that is the processor's own answer and a spec asking about one has
  # arranged "the processor said no".
  #
  # The figures are the committed fixture's plan priced for one seat: 1900 USD,
  # the plan the fixture subscriptions were created on. `total_excluding_tax`
  # is separate from `total` so the display delta the controller computes is
  # exercised as a subtraction rather than as a zero.
  InvoiceLine = Data.define(:description, :period, :quantity, :price, :amount, :currency)
  InvoicePeriod = Data.define(:start, :end)
  InvoicePrice = Data.define(:unit_amount)
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
          price: InvoicePrice.new(amount),
          amount: amount,
          currency: "usd"
        )
      ],
      subtotal: amount,
      total_excluding_tax: amount,
      total: amount + 247
    )
  end

  # The portal URL, from the processor. Recorded like every other request; the
  # customer and the return path are what went out, and the URL is the
  # processor's own.
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

    def refuse_unknown_subscription(id)
      return if KNOWN_SUBSCRIPTIONS.include?(id)

      raise StripeRefused, "No such subscription: #{id}"
    end
end
