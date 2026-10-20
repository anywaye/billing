# frozen_string_literal: true

# ask-tokens configuration.
# The railtie auto-wires the ActiveRecord store. Override settings here.

Ask::Tokens.configure do |config|
  # What 1M billing tokens cost (the rate your users pay).
  # config.price_per_1m = Money.from_amount(100, "USD")  # $100 / 1M

  # Rounding strategy for dynamic token costs: :ceil (default), :floor, :round.
  # config.rounding = :ceil

  # Allow negative balances? Default: false.
  # config.negatives = false
end
