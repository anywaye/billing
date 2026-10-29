require "test_helper"

class Subscriptions::PlanChangeTest < ActiveSupport::TestCase
  TIMING_CASES = {
    "the same price" => { from: 1900, to: 1900, timing: :period_end },
    "one cent more" => { from: 1900, to: 1901, timing: :immediately },
    "one cent less" => { from: 1900, to: 1899, timing: :period_end },
    "a lot more" => { from: 1900, to: 99_00, timing: :immediately },
    "a lot less" => { from: 99_00, to: 1900, timing: :period_end },
    "from free to paid" => { from: 0, to: 100, timing: :immediately },
    "from paid to free" => { from: 100, to: 0, timing: :period_end }
  }.freeze

  TIMING_CASES.each do |name, expected|
    test "#{name} takes effect #{expected[:timing].to_s.tr('_', ' ')}" do
      change = change_between(expected[:from], expected[:to])

      assert_equal expected[:timing], change.timing
    end
  end

  test "a change to the same plan is neither an upgrade nor a downgrade" do
    change = change_between(1900, 1900)

    assert_not change.upgrade?
    assert_not change.downgrade?
  end

  test "a more expensive plan is an upgrade" do
    change = change_between(1900, 2900)

    assert_predicate change, :upgrade?
    assert_not change.downgrade?
  end

  test "a cheaper plan is a downgrade" do
    change = change_between(2900, 1900)

    assert_predicate change, :downgrade?
    assert_not change.upgrade?
  end

  test "an upgrade invoices the difference immediately" do
    change = change_between(1900, 2900)

    assert_equal "always_invoice", change.proration_behavior
  end

  test "a downgrade carries nothing forward" do
    change = change_between(2900, 1900)

    assert_equal "none", change.proration_behavior
  end

  test "a change to the same price carries nothing forward" do
    change = change_between(1900, 1900)

    assert_equal "none", change.proration_behavior
  end

  test "the processor is told the price of the plan being moved to" do
    change = change_between(1900, 2900)

    assert_equal "price_2900", change.to_price_id
  end

  test "a change names the plan it is leaving as well as the one it is going to" do
    change = change_between(1900, 2900)

    assert_equal plan(1900), change.from
    assert_equal plan(2900), change.to
  end

  test "a change between currencies is refused" do
    change = Subscriptions::PlanChange.new(from: usd_plan(1900), to: eur_plan(1900))

    error = assert_raises(Billing::Money::CurrencyMismatchError) { change.timing }

    assert_match(/USD/, error.message)
    assert_match(/EUR/, error.message)
  end

  test "a change between currencies is refused before anything is compared" do
    change = Subscriptions::PlanChange.new(from: usd_plan(1900), to: eur_plan(1900))

    assert_raises(Billing::Money::CurrencyMismatchError) { change.upgrade? }
    assert_raises(Billing::Money::CurrencyMismatchError) { change.downgrade? }
  end

  test "a change between intervals is refused, because the prices are not the same unit" do
    monthly = plan(1900)
    yearly = Plan.create!(name: "Pro yearly", slug: "pro-yearly", price: Billing::Money.new(19_000, "USD"), interval: "year")

    change = Subscriptions::PlanChange.new(from: monthly, to: yearly)

    assert_raises(Subscriptions::PlanChange::IntervalMismatch) { change.timing }
  end

  test "an interval refusal says which intervals were compared" do
    monthly = plan(1900)
    yearly = Plan.create!(name: "Pro yearly", slug: "pro-yearly", price: Billing::Money.new(19_000, "USD"), interval: "year")

    change = Subscriptions::PlanChange.new(from: monthly, to: yearly)

    error = assert_raises(Subscriptions::PlanChange::IntervalMismatch) { change.timing }
    assert_match(/month/, error.message)
    assert_match(/year/, error.message)
  end

  test "an interval refusal does not report a timing" do
    monthly = plan(1900)
    yearly = Plan.create!(name: "Pro yearly", slug: "pro-yearly", price: Billing::Money.new(19_000, "USD"), interval: "year")

    change = Subscriptions::PlanChange.new(from: monthly, to: yearly)

    assert_raises(Subscriptions::PlanChange::IntervalMismatch) { change.upgrade? }
    assert_raises(Subscriptions::PlanChange::IntervalMismatch) { change.downgrade? }
  end

  test "a zero-decimal currency is compared in its own units" do
    change = Subscriptions::PlanChange.new(
      from: jpy_plan(1000),
      to: jpy_plan(2000)
    )

    assert_equal :immediately, change.timing
  end

  test "a three-decimal currency is compared in its own units" do
    change = Subscriptions::PlanChange.new(
      from: kwd_plan(1000),
      to: kwd_plan(999)
    )

    assert_equal :period_end, change.timing
  end

  test "the change never computes an amount" do
    change = change_between(1900, 2900)

    refute_respond_to change, :credit
    refute_respond_to change, :refund
    refute_respond_to change, :prorated_amount
    refute_respond_to change, :amount
  end

  test "a plan that has no processor price cannot be changed to" do
    change = Subscriptions::PlanChange.new(
      from: plan(1900, processor_price_id: "price_from"),
      to: plan(2900, processor_price_id: nil)
    )

    assert_raises(Subscriptions::PlanChange::Unpriced) { change.to_price_id }
  end

  test "an unpriced refusal names the plan that has no price" do
    change = Subscriptions::PlanChange.new(
      from: plan(1900, processor_price_id: "price_from"),
      to: plan(2900, processor_price_id: nil)
    )

    error = assert_raises(Subscriptions::PlanChange::Unpriced) { change.to_price_id }
    assert_match(/price/, error.message)
  end

  test "the timing does not need a processor price, because it is a comparison of two plans" do
    change = Subscriptions::PlanChange.new(
      from: plan(1900, processor_price_id: "price_from"),
      to: plan(2900, processor_price_id: nil)
    )

    assert_equal :immediately, change.timing
  end

  private
    def change_between(from_minor, to_minor)
      Subscriptions::PlanChange.new(from: plan(from_minor), to: plan(to_minor))
    end

    def plan(minor, processor_price_id: "price_#{minor}")
      @plans ||= {}
      @plans[[ minor, processor_price_id ]] ||= Plan.new(
        name: "Plan #{minor}",
        slug: "plan-#{minor}-#{@plans.size}",
        price: Billing::Money.new(minor, "USD"),
        interval: "month",
        processor_price_id: processor_price_id
      )
    end

    def usd_plan(minor)
      plan(minor)
    end

    def eur_plan(minor)
      Plan.new(
        name: "Plan #{minor} EUR",
        slug: "plan-#{minor}-eur-#{@plans&.size}",
        price: Billing::Money.new(minor, "EUR"),
        interval: "month",
        processor_price_id: "price_eur_#{minor}"
      )
    end

    def jpy_plan(minor)
      Plan.new(
        name: "Plan #{minor} JPY",
        slug: "plan-#{minor}-jpy-#{@plans&.size}",
        price: Billing::Money.new(minor, "JPY"),
        interval: "month",
        processor_price_id: "price_jpy_#{minor}"
      )
    end

    def kwd_plan(minor)
      Plan.new(
        name: "Plan #{minor} KWD",
        slug: "plan-#{minor}-kwd-#{@plans&.size}",
        price: Billing::Money.new(minor, "KWD"),
        interval: "month",
        processor_price_id: "price_kwd_#{minor}"
      )
    end
end
