module Billing
# An amount of money, held as an integer number of minor units.
#
# This is the seed of the platform-wide rule that money is *integer minor
# units* (PLAN §3). Consequences, all of them deliberate:
#
# * There is no Float in this file. A Float cannot represent 0.10, so it must
#   never carry an amount. Floats are rejected on the way in, not converted.
# * Nothing is rounded. Converting a major-unit amount that is smaller than one
#   minor unit raises instead of quietly losing the remainder, because a
#   silently rounded price is a bug that shows up in somebody's invoice.
# * Every operation is range-checked against the PostgreSQL bigint bounds, so a
#   value that cannot be stored is refused before it reaches the database.
# * Mixing currencies is an error, never a conversion. FX belongs in a pricing
#   decision, not in an arithmetic operator.
#
# Usage:
#
#   Money.new(1050, "USD")               #=> #<Money 10.50 USD>
#   Money.from_major("10.50", "USD")     #=> #<Money 10.50 USD>
#   Money.from_major("10.505", "USD")    # raises Money::InvalidAmountError
#   Money.new(1050, "USD") + Money.new(50, "USD")  #=> #<Money 11.00 USD>
#   Money.new(1050, "USD") * 3           #=> #<Money 31.50 USD>
#
# Currency codes are validated for ISO 4217 *shape* (three letters). The full
# list of active codes is not embedded here: a hand-maintained list of 180 codes
# is a liability in a payment system, and an unrecognised-but-well-formed code
# should not stop a new currency from being accepted before the catalogue lands.
# The exponents that differ from the usual two — zero-decimal currencies such as
# JPY and three-decimal ones such as KWD — are listed, because those are the ones
# that silently corrupt an amount if they are assumed.
class Money
  include Comparable

  # Base class for every error raised here, so a caller can rescue Money::Error
  # and be sure it caught a money problem rather than an unrelated bug.
  class Error < StandardError; end

  # The amount is not an integer number of minor units, is not a whole amount of
  # major units, or would lose sub-minor precision.
  class InvalidAmountError < Error; end

  # The currency is not a three-letter ISO 4217 code.
  class InvalidCurrencyError < Error; end

  # Two amounts in different currencies cannot be added or subtracted.
  class CurrencyMismatchError < Error; end

  # The amount does not fit in a PostgreSQL bigint.
  class OverflowError < Error; end

  DEFAULT_EXPONENT = 2

  MAX_MINOR_UNITS = (2**63) - 1
  MIN_MINOR_UNITS = -(2**63)
  MINOR_UNITS_RANGE = (MIN_MINOR_UNITS..MAX_MINOR_UNITS).freeze

  CURRENCY_FORMAT = /\A[A-Z]{3}\z/

  EXPONENTS = {
    "BIF" => 0,
    "CLP" => 0,
    "DJF" => 0,
    "GNF" => 0,
    "ISK" => 0,
    "JPY" => 0,
    "KMF" => 0,
    "KRW" => 0,
    "PYG" => 0,
    "RWF" => 0,
    "UGX" => 0,
    "UYI" => 0,
    "VND" => 0,
    "VUV" => 0,
    "XAF" => 0,
    "XOF" => 0,
    "XPF" => 0,
    "BHD" => 3,
    "IQD" => 3,
    "JOD" => 3,
    "KWD" => 3,
    "LYD" => 3,
    "OMR" => 3,
    "TND" => 3,
    "CLF" => 4,
    "UYW" => 4
  }.freeze

  class << self
    # Builds an amount from a number of major units, as a String, Integer or
    # BigDecimal. Raises rather than rounding if the value is not a whole
    # number of minor units.
    def from_major(major, currency)
      code = normalize_currency(currency)
      new(to_minor_units(major, code), code)
    end

    # A zero amount in the given currency.
    def zero(currency)
      new(0, currency)
    end

    # Upcases and validates a currency code. Accepts a Symbol so that callers
    # writing :USD get the same normalisation as "usd".
    def normalize_currency(currency)
      code = case currency
      when String, Symbol then currency.to_s.upcase
      else raise InvalidCurrencyError, "currency must be an ISO 4217 code, got #{currency.inspect}"
      end

      unless CURRENCY_FORMAT.match?(code)
        raise InvalidCurrencyError, "currency must be a three-letter ISO 4217 code, got #{code.inspect}"
      end

      code.freeze
    end

    private
      def to_minor_units(major, currency)
        value = case major
        when Integer then BigDecimal(major)
        when BigDecimal then major
        when String then parse_major(major)
        else raise InvalidAmountError,
          "amount must be an Integer in minor units, or a whole amount of major units, got #{major.inspect}"
        end

        unless value.finite?
          raise InvalidAmountError, "amount must be a finite number, got #{major.inspect}"
        end

        scaled = value * (10**EXPONENTS.fetch(currency, DEFAULT_EXPONENT))

        unless scaled.frac.zero?
          raise InvalidAmountError,
            "#{major.inspect} #{currency} is smaller than one minor unit and would be rounded"
        end

        scaled.to_i
      end

      def parse_major(major)
        BigDecimal(major)
      rescue ArgumentError, TypeError
        raise InvalidAmountError, "amount is not a number, got #{major.inspect}"
      end
  end

  # Builds an amount from an integer number of minor units. The amount is
  # validated here and nowhere else, so every Money that exists — however it was
  # produced, by arithmetic or by a database cast — is in range and integral.
  def initialize(minor_units, currency)
    unless minor_units.is_a?(Integer)
      raise InvalidAmountError, "amount must be an integer number of minor units, got #{minor_units.inspect}"
    end

    unless MINOR_UNITS_RANGE.cover?(minor_units)
      raise OverflowError, "amount #{minor_units} is outside the storable bigint range"
    end

    @minor_units = minor_units
    @currency = self.class.normalize_currency(currency)
    freeze
  end

  attr_reader :minor_units

  attr_reader :currency

  # Number of minor units per major unit for this currency.
  def exponent
    EXPONENTS.fetch(currency, DEFAULT_EXPONENT)
  end

  def +(other)
    code = check_compatible!(other)
    self.class.new(minor_units + other.minor_units, code)
  end

  def -(other)
    code = check_compatible!(other)
    difference = minor_units - other.minor_units

    if difference.negative?
      raise InvalidAmountError, "#{other} is more than #{self}; express that as a refund or a negative amount"
    end

    self.class.new(difference, code)
  end

  # Scales by a whole quantity, as in price * seats. A fractional multiplier is
  # refused: dividing money by a fraction is where rounding bugs are born.
  def *(quantity)
    unless quantity.is_a?(Integer)
      raise InvalidAmountError, "quantity must be an integer, got #{quantity.inspect}"
    end

    self.class.new(minor_units * quantity, currency)
  end

  def -@
    self.class.new(-minor_units, currency)
  end

  def abs
    self.class.new(minor_units.abs, currency)
  end

  # With no argument, is this amount zero? With a currency, is it zero *in that
  # currency* — the "an account settles at zero" check.
  def zero?(other_currency = nil)
    return minor_units.zero? if other_currency.nil?

    currency == self.class.normalize_currency(other_currency) && minor_units.zero?
  end

  def positive?
    minor_units.positive?
  end

  def negative?
    minor_units.negative?
  end

  # nil for an incomparable operand, which makes Comparable raise on `<` across
  # currencies instead of guessing an order.
  def <=>(other)
    return nil unless other.is_a?(Money) && other.currency == currency

    minor_units <=> other.minor_units
  end

  def ==(other)
    other.is_a?(Money) && other.currency == currency && other.minor_units == minor_units
  end

  alias_method :eql?, :==

  def hash
    [ self.class, minor_units, currency ].hash
  end

  def to_s
    units, fraction = minor_units.abs.divmod(10**exponent)
    sign = minor_units.negative? ? "-" : ""
    decimals = exponent.zero? ? "" : ".#{fraction.to_s.rjust(exponent, "0")}"

    "#{sign}#{units}#{decimals} #{currency}"
  end

  def inspect
    "#<#{self.class.name} #{self}>"
  end

  # The wire shape. String keys, so `render json:` and a cached payload are the
  # same thing. An amount always crosses a boundary as minor units.
  def to_h
    { "amount_minor" => minor_units, "currency" => currency }
  end

  alias_method :as_json, :to_h

  # For interop with libraries that speak major units. Never stored.
  def to_major
    BigDecimal(minor_units) / (10**exponent)
  end

  private
    def check_compatible!(other)
      raise CurrencyMismatchError, "cannot combine #{self} with a #{other.class}" unless other.is_a?(Money)

      unless other.currency == currency
        raise CurrencyMismatchError, "cannot combine #{self} with #{other}: different currencies are not interchangeable"
      end

      currency
    end
end
end
