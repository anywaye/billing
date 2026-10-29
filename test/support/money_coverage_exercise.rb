module MoneyCoverageExercise
  module_function

  def attempt
    { raised: nil, value: yield }
  rescue StandardError => e
    { raised: e }
  end

  def plans
    @plans ||= { monthly: {}, yearly: {}, other: {}, unpriced: {}, jpy: {}, kwd: {} }
  end

  def plan(kind, minor, price_id, currency: "USD", interval: "month")
    plans.fetch(kind)[[ minor, price_id ]] ||= Plan.new(
      name: "#{kind} #{minor} #{price_id}",
      slug: "#{kind}-#{minor}-#{price_id}",
      price: Billing::Money.new(minor, currency),
      interval: interval,
      processor_price_id: price_id
    )
  end

  def change(from, to)
    attempt { Subscriptions::PlanChange.new(from: from, to: to) }
  end

  def exercise_change(subject)
    [ attempt { subject.timing }, attempt { subject.upgrade? }, attempt { subject.downgrade? },
      attempt { subject.proration_behavior }, attempt { subject.to_price_id } ]
  end

  def full
    call
  end

  def minimal
    Billing::Money.zero("USD")
  end

  def call
    Billing::Money.new(1900, "USD")
    Billing::Money.new(1900, "usd")
    Billing::Money.new(1900, :usd)
    Billing::Money.new(0, "JPY")
    Billing::Money.new(1, "KWD")
    Billing::Money.new(1, "CLF")
    Billing::Money.new(Billing::Money::MAX_MINOR_UNITS, "USD")
    Billing::Money.new(Billing::Money::MIN_MINOR_UNITS, "USD")
    attempt { Billing::Money.new(10.5, "USD") }
    attempt { Billing::Money.new(nil, "USD") }
    attempt { Billing::Money.new(100, "US") }
    attempt { Billing::Money.new(100, nil) }
    attempt { Billing::Money.new(100, 840) }
    attempt { Billing::Money.new(Billing::Money::MAX_MINOR_UNITS + 1, "USD") }
    attempt { Billing::Money.new(Billing::Money::MIN_MINOR_UNITS - 1, "USD") }

    Billing::Money.from_major("10.50", "USD")
    Billing::Money.from_major(10, "USD")
    Billing::Money.from_major(BigDecimal("0.01"), "USD")
    Billing::Money.from_major("1000", "JPY")
    Billing::Money.from_major("1.234", "KWD")
    Billing::Money.from_major("1.2345", "CLF")
    attempt { Billing::Money.from_major("10.505", "USD") }
    attempt { Billing::Money.from_major("10.5", "JPY") }
    attempt { Billing::Money.from_major("1.2345", "KWD") }
    attempt { Billing::Money.from_major("10.5", "USD") }
    attempt { Billing::Money.from_major("92233720368547758.08", "USD") }
    attempt { Billing::Money.from_major("10.00", "nope") }
    attempt { Billing::Money.from_major(1..2, "USD") }
    attempt { Billing::Money.from_major(BigDecimal("NaN"), "USD") }
    attempt { Billing::Money.from_major("abc", "USD") }
    Billing::Money.zero("jpy")

    Billing::Money.new(1050, "USD") + Billing::Money.new(250, "USD")
    Billing::Money.new(1050, "USD") - Billing::Money.new(50, "USD")
    Billing::Money.new(1000, "USD") - Billing::Money.new(250, "USD")
    Billing::Money.new(1050, "USD") * 3
    Billing::Money.new(1050, "USD") * 0
    Billing::Money.new(1050, "USD") * -2
    -Billing::Money.new(1050, "USD")
    Billing::Money.new(-1050, "USD").abs
    Billing::Money.new(1050, "USD").abs
    attempt { Billing::Money.new(Billing::Money::MAX_MINOR_UNITS, "USD") + Billing::Money.new(1, "USD") }
    attempt { Billing::Money.new(100, "USD") + Billing::Money.new(100, "EUR") }
    attempt { Billing::Money.new(100, "USD") + 100 }
    attempt { Billing::Money.new(100, "USD") - Billing::Money.new(100, "EUR") }
    attempt { Billing::Money.new(100, "USD") - Billing::Money.new(250, "USD") }
    attempt { Billing::Money.new(1050, "USD") * 1.5 }
    attempt { Billing::Money.new(1050, "USD") * Billing::Money.new(2, "USD") }
    attempt { Billing::Money.new(1050, "USD") * 2 }

    Billing::Money.new(0, "USD").zero?
    Billing::Money.new(0, "USD").zero?("usd")
    Billing::Money.new(0, "USD").zero?("EUR")
    Billing::Money.new(1, "USD").zero?("USD")
    attempt { Billing::Money.new(0, "USD").zero?("nope") }
    Billing::Money.new(1, "USD").positive?
    Billing::Money.new(-1, "USD").negative?
    Billing::Money.new(100, "USD") <=> Billing::Money.new(100, "USD")
    Billing::Money.new(100, "USD") == Billing::Money.new(200, "USD")
    Billing::Money.new(100, "USD") == Billing::Money.new(100, "EUR")
    Billing::Money.new(100, "USD") == 100
    Billing::Money.new(100, "USD").hash
    Billing::Money.new(100, "USD").eql?(Billing::Money.new(100, "EUR"))
    Billing::Money.new(100, "USD") <=> 100
    begin
      Billing::Money.new(100, "USD") < Billing::Money.new(200, "EUR")
    rescue ArgumentError
      nil
    end

    Billing::Money.new(1050, "USD").to_s
    Billing::Money.new(100, "USD").to_s
    Billing::Money.new(5, "USD").to_s
    Billing::Money.new(0, "USD").to_s
    Billing::Money.new(-2550, "USD").to_s
    Billing::Money.new(1000, "JPY").to_s
    Billing::Money.new(1234, "KWD").to_s
    Billing::Money.new(12_345, "CLF").to_s
    Billing::Money.new(1050, "USD").to_h
    Billing::Money.new(1050, "USD").to_major
    Billing::Money.new(-1234, "KWD").to_major
    Billing::Money.new(1000, "JPY").to_major
    Billing::Money.new(1, "USD").exponent

    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1900, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1901, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1899, "b"))[:value]
    exercise_change change(plan(:monthly, 0, "a"), plan(:monthly, 100, "b"))[:value]
    exercise_change change(plan(:monthly, 100, "a"), plan(:monthly, 0, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:other, 1900, "b", currency: "EUR"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:yearly, 19_000, "b", interval: "year"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:unpriced, 2900, "b"))[:value]
    exercise_change change(plan(:jpy, 1000, "a"), plan(:jpy, 2000, "b"))[:value]
    exercise_change change(plan(:kwd, 1000, "a"), plan(:kwd, 999, "b"))[:value]
  end
end
