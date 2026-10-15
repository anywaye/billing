require "test_helper"

# The inventory of money paths, which is what keeps the coverage gate honest over
# time.
#
# `test/coverage/money_paths_coverage_test.rb` measures a *list* of files. A list
# that is never checked against the repository is a list that quietly stops
# covering code added after it: the new money path goes ungated and the gate stays
# green, which is the failure mode a coverage gate exists to prevent.
#
# So this file partitions every file that touches money into exactly two groups,
# and asserts the partition is complete:
#
#   * **A money path** — the file exists to be about amounts, and is held to 100%
#     line and branch coverage. `app/models/money.rb` and
#     `Subscriptions::PlanChange` are the two.
#   * **A file with money in it** — it builds, parses or reads an amount as one
#     part of a larger job, and is not line-gated. The amount is still reached
#     and still checked; that is asserted at the bottom of this file, because
#     "not in the gate's list" must never quietly come to mean "not covered".
#
# The second group carries its reason in `MIXED_MONEY_FILES`, and the reason is
# asserted to still apply, so an entry cannot rot into a claim nothing checks.
class MoneyPathInventoryTest < ActiveSupport::TestCase
  # The gate's list, read from the file that declares it rather than duplicated.
  # A second copy is a second thing to forget when the list changes.
  GATE = Rails.root.join("test/coverage/money_paths_coverage_test.rb").freeze

  MONEY_PATHS = %w[
    app/models/money.rb
    app/services/subscriptions/plan_change.rb
  ].freeze

  # Files that touch money and are not money paths, each with why. The reason is
  # a claim about what the file is *for*, and the two tests below check that the
  # claim is still true: the file still touches money, and it still has other
  # business of its own.
  MIXED_MONEY_FILES = {
    # Added in billing-04, and the inventory test is what put it here: the
    # controller serializes a plan's price on every subscription read, so it touches
    # money, and it makes no decision about an amount. Which way a plan change is
    # priced lives in `Subscriptions::PlanChange`, which *is* gated.
    "app/controllers/v1/subscriptions_controller.rb" =>
      "it asks the processor to change a subscription and renders the result; the one amount it touches is a plan's price, read out and not decided",
    "app/lib/money_params.rb" =>
      "it parses a request body; the parse exists independently of the amount it returns",
    "app/models/plan.rb" =>
      "a plan is a name, a slug, a price and an interval, and the price is one attribute of four",
    "app/services/webhooks/stripe_events.rb" =>
      "it normalizes a processor payload; the amount is one field of a subscription",
    # The checkout path reads `processor_price_id` — the **processor's** id for a
    # price — and nothing else monetary. It is in this list because the word is in
    # the column name, not because it decides an amount: the checkout sends no
    # amount to anybody, which is the rule `AGENTS.md` (Money) states and the
    # reason the reason column exists. A per-unit quantity is multiplied at the
    # processor.
    "app/services/checkout/session.rb" =>
      "it reads a plan's `processor_price_id` to subscribe at the processor and never computes an amount; the price the customer is charged is the processor's, so no money decision happens here",
    # The receipt route formats a charge's amount for a person to read. It is in
    # this list and not the gate's because the amount is **read out and displayed**,
    # never decided: which way a price is priced lives in the plan, and the charge
    # records what the processor said. The formatting is still money code — minor
    # units in, a number with the currency's own exponent out — so it is asserted
    # behaviourally below rather than by being in the gate's list.
    "app/controllers/v1/charges_controller.rb" =>
      "it renders a receipt for a charge; the one amount it touches is the charge's, formatted with the currency's own exponent for a person to read and never decided"
  }.freeze

  # What each mixed file does with money, and the proof that it is reached and
  # correct. Keyed by file so the two lists cannot drift apart silently.
  MIXED_MONEY_ENTRY_POINTS = {
    "app/controllers/v1/subscriptions_controller.rb" => [ "Subscription#price, as serialized" ],
    "app/lib/money_params.rb" => %w[MoneyParams.parse],
    "app/models/plan.rb" => %w[Plan#price Plan#price=],
    "app/services/webhooks/stripe_events.rb" => %w[Webhooks::StripeEvents.money],
    # Reached and correct behaviourally, not just named: the checkout's negative
    # specs assert that a plan with no `processor_price_id` is refused rather than
    # given a price this service would have had to invent. See
    # `test/services/checkout/session_test.rb`.
    "app/services/checkout/session.rb" => [ "Checkout::Session#delivery" ],
    "app/controllers/v1/charges_controller.rb" => [ "V1::ChargesController#formatted_amount" ]
  }.freeze

  test "the gate's list and this list are the same list" do
    assert_equal MONEY_PATHS.sort, gated_paths.sort
  end

  test "every file that touches money is in one group or the other, and in only one" do
    mentioned = app_files.select { |path| source(path).match?(money_mention) }

    assert_empty mentioned - MONEY_PATHS - MIXED_MONEY_FILES.keys,
      "these files touch money and are in neither list: #{(mentioned - MONEY_PATHS - MIXED_MONEY_FILES.keys).inspect}"
    assert_empty MONEY_PATHS & MIXED_MONEY_FILES.keys,
      "a file cannot be gated and ungated at once: #{(MONEY_PATHS & MIXED_MONEY_FILES.keys).inspect}"
  end

  MIXED_MONEY_FILES.each do |file, reason|
    test "#{file} still touches money, or it belongs in neither list" do
      assert source(file).match?(money_mention),
        "#{file} no longer touches money, so it is not a mixed money file any more: #{reason}"
    end

    test "#{file} is still doing work that is not about money: #{reason}" do
      refute source(file).match?(/\A\s*(#.*\n)*\s*class \w+\n\s*end\s*\z/m),
        "#{file} now contains nothing but money, so it is a money path and belongs in the gate's list: #{reason}"
    end
  end

  test "the entry points each mixed file was credited with are the ones asserted below" do
    assert_equal MIXED_MONEY_FILES.keys.sort, MIXED_MONEY_ENTRY_POINTS.keys.sort
  end

  # The money code in a mixed file is not line-gated, so it is asserted here
  # instead: each entry point is called, and the amount that comes out is checked
  # to still be an integer number of minor units with its currency attached.
  MIXED_MONEY_ENTRY_POINTS.each do |file, entry_points|
    entry_points.each do |entry_point|
      test "#{entry_point} keeps money in integer minor units (#{file})" do
        assert_integer_minor_units_survive(entry_point)
      end
    end
  end

  test "the inventory found something, rather than matching an empty repository" do
    assert_operator app_files.size, :>, 10
    assert_operator (app_files.select { |path| source(path).match?(money_mention) }).size, :>=, MONEY_PATHS.size
  end

  private
    def assert_integer_minor_units_survive(entry_point)
      case entry_point
      when "Subscription#price, as serialized"
        # The subscription's wire shape carries the plan's price, and it is the same
        # crossing shape every other amount in this service uses: integer minor units
        # plus a currency, never a decimal and never a float.
        subscription = Subscription.new
        serialized = subscription.as_json.merge("price" => Plan.new(name: "P", slug: "p", price: Money.new(1900, "USD"), interval: "month").price.to_h)

        assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, serialized.fetch("price"))
        assert_instance_of Integer, serialized.dig("price", "amount_minor")
      when "MoneyParams.parse"
        # `parse` reads symbol keys, because a controller hands it
        # `ActionController::Parameters`. A plain string-keyed Hash is not what
        # the caller passes and would fail for the wrong reason.
        money, error = MoneyParams.parse(ActionController::Parameters.new(amount_minor: 1900, currency: "USD"))

        assert_nil error
        assert_equal Money.new(1900, "USD"), money
        assert_instance_of Integer, money.minor_units
        assert_predicate money, :frozen?
      when "Plan#price", "Plan#price="
        plan = Plan.new(name: "Pro", slug: "pro", price: Money.new(1900, "USD"), interval: "month")

        assert_equal Money.new(1900, "USD"), plan.price
        assert_instance_of Integer, plan.amount_cents
        # A Float is refused at the only place a price is written, which is the
        # reason the setter takes a Money at all.
        assert_raises(Money::InvalidAmountError) { plan.price = 19.0 }
      when "Webhooks::StripeEvents.money"
        shape = Webhooks::StripeEvents.money(1900, "usd")

        assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, shape)
        assert_instance_of Integer, shape.fetch("amount_minor")
      when "Checkout::Session#delivery"
        # The checkout builds the delivery a webhook would carry, and asserts here
        # what it **does not** contain: an amount. The price crosses as the
        # processor's own id for it (`price_id`), never as a number, because the
        # amount a customer is charged is the processor's to decide (`AGENTS.md`,
        # Money). So the proof that money survives this file as minor units is that
        # no minor-unit field leaves it at all, and that the plan's own price is
        # still an integer pair when the session reads it back.
        #
        # The subscription value is the fake processor's own — the same value
        # object `Processor::FakeClient` answers with. Constructed here rather
        # than subscribed for, because the delivery is read from it and that is
        # the whole of this entry point.
        customer = Customer.new(owner_type: "Account", owner_id: "11111111-1111-4111-8111-111111111111", processor: "stripe")
        plan = Plan.new(name: "Pro", slug: "pro", price: Money.new(1900, "USD"), interval: "month",
          processor_price_id: "price_FAKEcheckout000000")
        session = Checkout::Session.new(customer: customer, plan: plan, quantity: 3)

        subscription = Processor::FakeClient::ProcessorSubscription.new(
          processor_id: "sub_FAKEcheckout0000", processor_plan: "price_FAKEcheckout000000",
          quantity: 3, status: "active", trial_ends_at: nil, created_at: Time.current,
          price: Money.new(1900, "USD"), interval: "month"
        )
        delivery = session.send(:delivery, subscription)

        assert_equal "price_FAKEcheckout000000", delivery.fetch("price_id")
        assert_empty delivery.keys.grep(/amount|minor|total/)
        # The per-seat quantity is an Integer count of seats, not a multiplied
        # amount: nothing in this file computes one.
        assert_equal 3, delivery.fetch("quantity")
        assert_instance_of Integer, delivery.fetch("quantity")
        assert_equal Money.new(1900, "USD"), plan.price
        assert_instance_of Integer, plan.price.minor_units
      when "V1::ChargesController#formatted_amount"
        # The receipt's amount line: integer minor units in, a number with the
        # currency's own exponent and the currency spelled out beside it. The
        # zero-decimal case is the one that catches a hardcoded two places — a
        # yen receipt with a decimal point it has no minor unit for is the kind
        # of small wrongness only the customer notices.
        controller = V1::ChargesController.new

        assert_equal "19.00 USD", controller.send(:formatted_amount, Charge.new(amount: 1900, currency: "USD"))
        assert_equal "1900 JPY", controller.send(:formatted_amount, Charge.new(amount: 1900, currency: "JPY"))
      else
        raise "no assertion is defined for the entry point #{entry_point.inspect}"
      end
    end

    # A call that builds an amount, or reads one back out. `.to_h` alone is not
    # enough: half this repository serialises something to a hash, and a file that
    # renders a problem body is not a money path.
    def money_mention
      /\b(Money\.(new|from_major|zero)|#price\b)/
    end

    def gated_paths
      @gated_paths ||= GATE.read[/MONEY_PATHS = %w\[(.*?)\]/m, 1].split.map(&:strip)
    end

    def app_files
      @app_files ||= Dir[Rails.root.join("app/**/*.rb")].sort.map { |path| path.delete_prefix("#{Rails.root}/") }
    end

    def source(path)
      @source ||= {}
      @source[path] ||= File.read(Rails.root.join(path))
    end
end
