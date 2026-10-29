# Parses a price out of a request body, or refuses it.
#
# The only accepted shape is `{"amount_minor": <integer>, "currency": "XXX"}` —
# minor units, as an integer. A Float is refused rather than rounded, because
# `19.00` arriving as a float has already lost the fact that it was nineteen
# dollars exactly, and a decimal string is refused for the same reason. A price
# sent as `19.50` is not a rounding bug in this code; it is a client that has
# decided a Float may carry money, and answering it correctly is how that
# belief gets fixed.
#
# The error message is a fixed sentence on purpose: it names the shape that is
# wanted and never repeats what was sent or what the parser complained about.
module MoneyParams
  MESSAGE = "must be an object with an integer amount_minor and a three-letter currency"

  # [Billing::Money, nil] or [nil, MESSAGE]. Never raises: a request is untrusted input,
  # and a refusal is a 422 rather than a 500.
  #
  # `price` is duck-typed rather than checked against Hash, because an
  # `ActionController::Parameters` is not a Hash and refusing every well-formed
  # request because of that would be a worse bug than the one this guards. What
  # matters is only that the object answers to the two keys; a String or an
  # Array that happens to answer to `[]` fails on the key lookup, and the rescue
  # below turns that into the same refusal.
  def self.parse(price)
    return [ nil, MESSAGE ] unless price.respond_to?(:[])

    minor_units = price[:amount_minor]
    currency = price[:currency]

    return [ nil, MESSAGE ] unless minor_units.is_a?(Integer) && currency.is_a?(String)

    [ Billing::Money.new(minor_units, currency), nil ]
  rescue Billing::Money::Error
    [ nil, MESSAGE ]
  rescue TypeError, NoMethodError
    [ nil, MESSAGE ]
  end
end
