require "test_helper"

# When a plan change takes effect, and what the processor is told to do about
# the money in between.
#
# The rule, in one sentence: **a move to a more expensive plan takes effect
# immediately, a move to a cheaper or equal one takes effect at the end of the
# current period.** It is one rule rather than two because the two directions
# are the same decision read from opposite ends, and stating them separately
# invites them to disagree.
#
# Why this rule and not the other one:
#
#   * **An upgrade charges the difference now.** The customer asked for more
#     service, and getting it at the end of the period means they used it for
#     free in the meantime. The credit for the time already paid on the old plan
#     is the processor's to compute — this object never multiplies a price by a
#     fraction of a month.
#   * **A downgrade does not refund mid-period.** Nobody is refunded for a plan
#     they are already leaving, and a customer who downgrades to a cheaper plan
#     is not billed for the remainder at the new rate before the period ends.
#     Charging the difference downwards would mean issuing a credit, and a credit
#     this service computed would be a number that eventually disagreed with the
#     processor's own books.
#
# Both directions are one comparison of two `Billing::Money` values, which is the only
# arithmetic in this file and it is a comparison, not a calculation. Nothing
# here is a Float and nothing here is ever persisted.
#
# Two comparisons are refused rather than guessed:
#
#   * **Different currencies.** `Billing::Money#<=>` returns nil across currencies, and
#     Comparable would raise from an `>`. That is the right answer — FX is a
#     pricing decision, not something a plan change may make — but the refusal
#     has to be a named, tested outcome rather than an exception from a
#     comparison operator.
#   * **Different intervals.** Ten dollars a month against a hundred a year is
#     not a cheaper plan; it is a different product with a different unit. A
#     monthly price multiplied by twelve is an *annualised* figure and deciding
#     a billing change from one would be computing money that is not asked for.
class Subscriptions::PlanChangeTest < ActiveSupport::TestCase
  # (from minor, to minor) => expected timing. A table rather than a series of
  # `test` blocks, because the rule is a function of the comparison and the
  # interesting cases are the boundary ones: equal, one cent either side.
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

  # What the processor is asked to do with the money in between. `always_invoice`
  # makes the processor bill the difference now; `none` makes it carry nothing
  # forward. The amount is the processor's in both cases — this service sends a
  # behaviour, never a figure.
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

  # The refusals. Both are about comparing two prices that are not commensurable,
  # and both are named outcomes rather than an exception raised from `<`.
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

  # The prices are compared as `Billing::Money`, so a zero-decimal currency is compared in
  # its own minor units and never scaled by a hundred.
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

    # The only thing this object knows about money is which of two prices is
    # larger. There is no accessor for a credit, a refund or a prorated figure,
    # so there is nothing here to be wrong about one.
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

    # One plan per amount, so asking for the same price twice gives the same
    # object and `change.from` can be compared with `==` rather than with a slug.
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
