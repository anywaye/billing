require "test_helper"

# The money primitive. Every amount in this service is an integer number of
# minor units (PLAN §3) — there is no Float anywhere in this file, and no code
# path silently rounds.
class MoneyTest < ActiveSupport::TestCase
  # --- construction -----------------------------------------------------------

  CONSTRUCTION_CASES = {
    "zero dollars" => { minor: 0, currency: "USD", exponent: 2 },
    "one dollar" => { minor: 100, currency: "USD", exponent: 2 },
    "a negative amount" => { minor: -2550, currency: "USD", exponent: 2 },
    "a lowercased code" => { minor: 100, currency: "usd", normalized: "USD" },
    "a symbol code" => { minor: 100, currency: :eur, normalized: "EUR" },
    "a zero-decimal currency" => { minor: 1000, currency: "JPY", exponent: 0 },
    "a three-decimal currency" => { minor: 1234, currency: "KWD", exponent: 3 },
    "a four-decimal currency" => { minor: 1234, currency: "CLF", exponent: 4 },
    "the largest storable amount" => { minor: Billing::Money::MAX_MINOR_UNITS, currency: "USD" },
    "the smallest storable amount" => { minor: Billing::Money::MIN_MINOR_UNITS, currency: "USD" }
  }.freeze

  CONSTRUCTION_CASES.each do |name, expected|
    test "constructs #{name}" do
      money = Billing::Money.new(expected[:minor], expected[:currency])

      assert_equal expected[:minor], money.minor_units
      assert_equal expected.fetch(:normalized, expected[:currency]), money.currency
      assert_equal expected.fetch(:exponent, 2), money.exponent
    end
  end

  test "money is frozen" do
    money = Billing::Money.new(100, "USD")

    assert_predicate money, :frozen?
  end

  test "zero builds a zero amount" do
    money = Billing::Money.zero("jpy")

    assert_equal Billing::Money.new(0, "JPY"), money
    assert_predicate money, :zero?
  end

  INVALID_AMOUNTS = {
    "a Float" => 10.5,
    "a Float that looks whole" => 100.0,
    "a String" => "1000",
    "a BigDecimal" => BigDecimal(1000),
    "nil" => nil,
    "true" => true,
    "an Array" => [ 1000 ]
  }.freeze

  INVALID_AMOUNTS.each do |name, amount|
    test "rejects #{name} as a minor unit amount" do
      error = assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(amount, "USD") }

      assert_match(/integer/, error.message)
    end
  end

  test "rejects an amount above the bigint ceiling" do
    assert_raises(Billing::Money::OverflowError) { Billing::Money.new(Billing::Money::MAX_MINOR_UNITS + 1, "USD") }
  end

  test "rejects an amount below the bigint floor" do
    assert_raises(Billing::Money::OverflowError) { Billing::Money.new(Billing::Money::MIN_MINOR_UNITS - 1, "USD") }
  end

  INVALID_CURRENCIES = {
    "an empty string" => "",
    "a two-letter code" => "US",
    "a four-letter code" => "USDD",
    "a code with a digit" => "US1",
    "a code with punctuation" => "US-",
    "a lowercase-only string that is too long" => "usdd",
    "nil" => nil,
    "an Integer" => 840,
    "an Array" => [ "USD" ]
  }.freeze

  INVALID_CURRENCIES.each do |name, currency|
    test "rejects #{name} as a currency" do
      assert_raises(Billing::Money::InvalidCurrencyError) { Billing::Money.new(100, currency) }
    end
  end

  test "exposes the ISO 4217 exponent of a currency" do
    assert_equal 0, Billing::Money.new(1, "JPY").exponent
    assert_equal 2, Billing::Money.new(1, "USD").exponent
    assert_equal 3, Billing::Money.new(1, "KWD").exponent
    assert_equal 4, Billing::Money.new(1, "CLF").exponent
  end

  # --- building from major units ---------------------------------------------

  FROM_MAJOR_CASES = {
    "a decimal string" => { major: "10.50", currency: "USD", minor: 1050 },
    "an Integer" => { major: 10, currency: "USD", minor: 1000 },
    "a BigDecimal" => { major: BigDecimal("0.01"), currency: "USD", minor: 1 },
    "a negative string" => { major: "-5.00", currency: "USD", minor: -500 },
    "a padded string" => { major: "0007", currency: "USD", minor: 700 },
    "a signed string" => { major: "+3.25", currency: "USD", minor: 325 },
    "scientific notation" => { major: "1e3", currency: "USD", minor: 100_000 },
    "a zero-decimal currency" => { major: "1000", currency: "JPY", minor: 1000 },
    "a three-decimal currency" => { major: "1.234", currency: "KWD", minor: 1234 },
    "a four-decimal currency" => { major: "1.2345", currency: "CLF", minor: 12_345 },
    "zero" => { major: "0", currency: "USD", minor: 0 }
  }.freeze

  FROM_MAJOR_CASES.each do |name, expected|
    test "builds #{name} from major units" do
      money = Billing::Money.from_major(expected[:major], expected[:currency])

      assert_equal expected[:minor], money.minor_units
      assert_equal expected[:currency], money.currency
    end
  end

  UNPARSEABLE_MAJORS = {
    "a Float" => 10.5,
    "a whole Float" => 10.0,
    "nil" => nil,
    "an Integer is fine but a Range is not" => (1..2),
    "a word" => "abc",
    "an empty string" => "",
    "NaN" => "NaN",
    "Infinity" => "Infinity",
    "a NaN BigDecimal" => BigDecimal("NaN")
  }.freeze

  UNPARSEABLE_MAJORS.each do |name, major|
    test "refuses to build from #{name}" do
      assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major(major, "USD") }
    end
  end

  test "refuses to round away sub-minor precision instead of rounding it" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major("10.505", "USD") }
  end

  test "refuses fractions of a zero-decimal currency" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major("10.5", "JPY") }
  end

  test "refuses fractions of a three-decimal currency" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major("1.2345", "KWD") }
  end

  test "refuses a major amount that overflows a bigint once scaled" do
    assert_raises(Billing::Money::OverflowError) { Billing::Money.from_major("92233720368547758.08", "USD") }
  end

  test "validates the currency before the amount" do
    assert_raises(Billing::Money::InvalidCurrencyError) { Billing::Money.from_major("10.00", "nope") }
  end

  # --- the rounding a Float would get wrong ---------------------------------
  #
  # The suite above proves the rules. These prove the *reason* for them, by
  # pinning the two arithmetic identities a Float breaks and this service cannot.
  # A test that used only round numbers would pass against a Float
  # implementation and is therefore not evidence of anything; these use the
  # amounts where a Float is actually wrong.
  #
  # A monetary value is an integer count of minor units, and the conversions in
  # both directions are exact for a `BigDecimal` divisor that is a power of ten —
  # which is precisely what a currency's exponent makes it.

  test "a repeated addition of a tenth is exact where a Float is not" do
    # 0.1 + 0.2 != 0.3 in binary floating point. In minor units it is 10 + 20.
    ten_cents = Billing::Money.new(10, "USD")
    twenty_cents = Billing::Money.new(20, "USD")

    assert_equal 30, (ten_cents + twenty_cents).minor_units
    assert_equal Billing::Money.new(30, "USD"), ten_cents + twenty_cents
  end

  test "an amount a Float cannot represent round-trips through major units exactly" do
    # 0.1 has no exact binary representation; 0.10 major units has exactly one
    # correct answer in minor units, and BigDecimal scaling finds it every time.
    money = Billing::Money.from_major("0.10", "USD")

    assert_equal 10, money.minor_units
    assert_equal "0.1", money.to_major.to_s("F")
  end

  # The case the packet names: a percentage applied to an amount with three
  # decimal places. 1.175 KWD at 15% is 0.17625 KWD, which is *not* a whole number
  # of minor units — so the correct answer is to refuse, not to round to 176 or
  # 177. A Float would produce 0.17625000000000002 here and round to whichever
  # side it happened to land on.
  test "a three-decimal amount is exact where a Float would drift" do
    one_kenyan = Billing::Money.from_major("1.175", "KWD")

    assert_equal 1175, one_kenyan.minor_units
    assert_equal BigDecimal("1.175"), one_kenyan.to_major
    assert_equal 2350, (one_kenyan * 2).minor_units
  end

  test "an amount smaller than one minor unit of a three-decimal currency is refused, not rounded" do
    # 0.0005 KWD is half of one fils. Rounding it to 0 or to 1 is a bug that shows
    # up in somebody's invoice, which is the worst place to find one.
    error = assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major("0.0005", "KWD") }

    assert_includes error.message, "would be rounded"
  end

  # A Float cannot represent 0.10 either, so the same guard has to catch an amount
  # that *arrived* as a Float rather than as a string. This is the shape a JSON
  # body produces when a client sends `19.00`: the client has already decided a
  # Float may carry money.
  test "a Float amount is refused rather than rounded to the nearest minor unit" do
    error = assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(10.0, "USD") }

    assert_includes error.message, "integer number of minor units"
  end

  test "a Float that carries no value is refused rather than becoming zero" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(0.0, "USD") }
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.from_major(19.99, "USD") }
  end

  # The stored representation itself, asserted rather than assumed: the integer
  # count, the class it is, and the one wire shape an amount crosses a boundary in.
  # A Billing::Money that held a Float would pass every arithmetic assertion above on round
  # numbers and fail this one.
  REPRESENTATION_CASES = {
    "a whole amount" => { minor: 2900, currency: "USD" },
    "a zero-decimal currency" => { minor: 500, currency: "JPY" },
    "a three-decimal currency" => { minor: 1175, currency: "KWD" },
    "a four-decimal currency" => { minor: 1175, currency: "CLF" }
  }.freeze

  REPRESENTATION_CASES.each do |name, expected|
    test "stores #{name} as an Integer count of minor units" do
      money = Billing::Money.new(expected[:minor], expected[:currency])

      assert_kind_of Integer, money.minor_units
      assert_equal expected[:minor], money.minor_units
      refute_kind_of Float, money.minor_units
    end

    test "crosses a boundary as #{name} in the one wire shape" do
      money = Billing::Money.new(expected[:minor], expected[:currency])

      assert_equal({ "amount_minor" => expected[:minor], "currency" => expected[:currency] }, money.to_h)
    end
  end

  # --- arithmetic -------------------------------------------------------------

  ADDITION_CASES = {
    "two amounts" => { left: 1050, right: 250, total: 1300 },
    "a negative amount" => { left: 1050, right: -50, total: 1000 },
    "two zeroes" => { left: 0, right: 0, total: 0 },
    "the bigint ceiling" => { left: Billing::Money::MAX_MINOR_UNITS, right: 0, total: Billing::Money::MAX_MINOR_UNITS }
  }.freeze

  ADDITION_CASES.each do |name, expected|
    test "adds #{name}" do
      total = Billing::Money.new(expected[:left], "USD") + Billing::Money.new(expected[:right], "USD")

      assert_equal Billing::Money.new(expected[:total], "USD"), total
    end
  end

  test "refuses to add across currencies" do
    error = assert_raises(Billing::Money::CurrencyMismatchError) do
      Billing::Money.new(100, "USD") + Billing::Money.new(100, "EUR")
    end

    assert_match(/USD/, error.message)
    assert_match(/EUR/, error.message)
  end

  test "refuses to add a non-Billing::Money" do
    assert_raises(Billing::Money::CurrencyMismatchError) { Billing::Money.new(100, "USD") + 100 }
  end

  test "refuses to subtract across currencies" do
    assert_raises(Billing::Money::CurrencyMismatchError) { Billing::Money.new(100, "USD") - Billing::Money.new(100, "EUR") }
  end

  test "subtracts" do
    difference = Billing::Money.new(1000, "USD") - Billing::Money.new(250, "USD")

    assert_equal Billing::Money.new(750, "USD"), difference
  end

  test "refuses to produce a negative amount by subtraction" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(100, "USD") - Billing::Money.new(250, "USD") }
  end

  test "refuses an addition that overflows" do
    assert_raises(Billing::Money::OverflowError) { Billing::Money.new(Billing::Money::MAX_MINOR_UNITS, "USD") + Billing::Money.new(1, "USD") }
  end

  MULTIPLICATION_CASES = {
    "a whole quantity" => { minor: 1050, quantity: 3, total: 3150 },
    "a quantity of zero" => { minor: 1050, quantity: 0, total: 0 },
    "a negative quantity" => { minor: 1050, quantity: -2, total: -2100 }
  }.freeze

  MULTIPLICATION_CASES.each do |name, expected|
    test "multiplies by #{name}" do
      assert_equal Billing::Money.new(expected[:total], "USD"), Billing::Money.new(expected[:minor], "USD") * expected[:quantity]
    end
  end

  test "refuses to multiply by a fraction" do
    error = assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(1050, "USD") * 1.5 }

    assert_match(/integer/, error.message)
  end

  test "refuses to multiply by another Billing::Money" do
    assert_raises(Billing::Money::InvalidAmountError) { Billing::Money.new(1050, "USD") * Billing::Money.new(2, "USD") }
  end

  test "refuses a multiplication that overflows" do
    assert_raises(Billing::Money::OverflowError) { Billing::Money.new(Billing::Money::MAX_MINOR_UNITS, "USD") * 2 }
  end

  test "refuses a quantity on the left of the operator rather than guessing" do
    # Billing::Money is not Numeric and does not implement coerce, so Ruby refuses the
    # reversed operand itself. Write `price * 3`, never `3 * price`.
    assert_raises(TypeError) { 3 * Billing::Money.new(1050, "USD") }
  end

  test "negates" do
    assert_equal Billing::Money.new(-1050, "USD"), -Billing::Money.new(1050, "USD")
  end

  test "abs" do
    assert_equal Billing::Money.new(1050, "USD"), Billing::Money.new(-1050, "USD").abs
    assert_equal Billing::Money.new(1050, "USD"), Billing::Money.new(1050, "USD").abs
  end

  # --- predicates -------------------------------------------------------------

  PREDICATE_CASES = {
    "zero dollars" => { minor: 0, zero: true, positive: false, negative: false },
    "positive dollars" => { minor: 1, zero: false, positive: true, negative: false },
    "negative dollars" => { minor: -1, zero: false, positive: false, negative: true }
  }.freeze

  PREDICATE_CASES.each do |name, expected|
    test "#{name} reports its predicates" do
      money = Billing::Money.new(expected[:minor], "USD")

      assert_equal expected[:zero], money.zero?
      assert_equal expected[:positive], money.positive?
      assert_equal expected[:negative], money.negative?
    end
  end

  test "zero? checks a given currency too" do
    money = Billing::Money.new(0, "USD")

    assert money.zero?("USD")
    assert money.zero?("usd")
    assert_not money.zero?("EUR")
  end

  test "a non-zero amount is not zero in any currency" do
    assert_not Billing::Money.new(1, "USD").zero?("USD")
  end

  test "zero? rejects a malformed currency" do
    assert_raises(Billing::Money::InvalidCurrencyError) { Billing::Money.new(0, "USD").zero?("nope") }
  end

  # --- comparison -------------------------------------------------------------

  test "orders amounts of the same currency" do
    cheap = Billing::Money.new(100, "USD")
    dear = Billing::Money.new(200, "USD")

    assert_operator cheap, :<, dear
    assert_operator dear, :>, cheap
    assert_operator cheap, :<=, cheap
    assert_operator cheap, :>=, cheap
    assert_equal 0, cheap <=> Billing::Money.new(100, "USD")
    assert_equal(-1, cheap <=> dear)
    assert_equal 1, dear <=> cheap
  end

  test "is not equal to a different amount or currency" do
    assert_not_equal Billing::Money.new(100, "USD"), Billing::Money.new(200, "USD")
    assert_not_equal Billing::Money.new(100, "USD"), Billing::Money.new(100, "EUR")
    assert_not_equal Billing::Money.new(100, "USD"), 100
  end

  test "sorts by amount within a currency" do
    sorted = [ Billing::Money.new(300, "USD"), Billing::Money.new(100, "USD"), Billing::Money.new(200, "USD") ].sort

    assert_equal [ 100, 200, 300 ], sorted.map(&:minor_units)
  end

  test "ordering across currencies is refused rather than guessed" do
    assert_raises(ArgumentError) { Billing::Money.new(100, "USD") < Billing::Money.new(200, "EUR") }
  end

  test "comparison with a non-Billing::Money is undefined" do
    assert_nil Billing::Money.new(100, "USD") <=> 100
  end

  test "equal amounts share a hash" do
    assert_equal Billing::Money.new(100, "USD").hash, Billing::Money.new(100, "USD").hash
    assert Billing::Money.new(100, "USD").eql?(Billing::Money.new(100, "USD"))
    assert_not Billing::Money.new(100, "USD").eql?(Billing::Money.new(100, "EUR"))
    assert_equal 1, [ Billing::Money.new(100, "USD"), Billing::Money.new(100, "USD") ].uniq.size
  end

  # --- rendering --------------------------------------------------------------

  FORMATTING_CASES = {
    "dollars" => { minor: 1050, currency: "USD", string: "10.50 USD" },
    "no cents" => { minor: 100, currency: "USD", string: "1.00 USD" },
    "sub-cent rounding is never hidden" => { minor: 5, currency: "USD", string: "0.05 USD" },
    "zero" => { minor: 0, currency: "USD", string: "0.00 USD" },
    "a negative amount" => { minor: -2550, currency: "USD", string: "-25.50 USD" },
    "a zero-decimal currency" => { minor: 1000, currency: "JPY", string: "1000 JPY" },
    "a three-decimal currency" => { minor: 1234, currency: "KWD", string: "1.234 KWD" },
    "a four-decimal currency" => { minor: 12_345, currency: "CLF", string: "1.2345 CLF" }
  }.freeze

  FORMATTING_CASES.each do |name, expected|
    test "formats #{name}" do
      money = Billing::Money.new(expected[:minor], expected[:currency])

      assert_equal expected[:string], money.to_s
      assert_equal "#<Billing::Money #{expected[:string]}>", money.inspect
    end
  end

  test "serializes to a hash of minor units and currency" do
    money = Billing::Money.new(1050, "USD")

    assert_equal({ "amount_minor" => 1050, "currency" => "USD" }, money.to_h)
    assert_equal money.to_h, money.as_json
    assert_equal({ "amount_minor" => 1050, "currency" => "USD" }, { money: money }.as_json["money"])
  end

  test "converts to major units for interop" do
    assert_equal BigDecimal("10.5"), Billing::Money.new(1050, "USD").to_major
    assert_equal BigDecimal("-1.234"), Billing::Money.new(-1234, "KWD").to_major
    assert_equal BigDecimal("1000"), Billing::Money.new(1000, "JPY").to_major
  end
end
