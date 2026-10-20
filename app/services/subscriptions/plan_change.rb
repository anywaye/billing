module Subscriptions
  # When a plan change takes effect, and what the processor is told to do about
  # the money in between.
  #
  # **The rule: a move to a more expensive plan takes effect immediately; a move
  # to a cheaper or equal one takes effect at the end of the current period.**
  # One rule, not two, because the two directions are the same decision read from
  # opposite ends and stating them separately invites them to disagree.
  #
  # Why this way round:
  #
  #   * **An upgrade charges the difference now.** The customer asked for more
  #     service, and delivering it at the end of the period means they used it for
  #     free in between. The credit for the part of the period already paid on the
  #     old plan is the processor's to compute.
  #   * **A downgrade does not refund mid-period.** Nobody is refunded for a plan
  #     they are already leaving, and a customer who moves to a cheaper plan is not
  #     billed at the new rate for the remainder of a period they paid for at the
  #     old one. That would mean issuing a credit, and a credit this service
  #     computed would eventually disagree with the processor's own books.
  #
  # So the only thing this object does with money is compare two of them, and a
  # comparison of `Billing::Money` values is the only arithmetic in this file. There is no
  # credit, no refund, no prorated figure and no annualisation: the processor is
  # sent a *behaviour* (`always_invoice` or `none`) and computes the number.
  # Nothing here is a Float, and nothing here is persisted.
  #
  # Two comparisons are refused rather than guessed, and both refusals matter
  # because a wrong answer is a wrong amount of money:
  #
  #   * **Different currencies.** `Billing::Money#<=>` is nil across currencies, so a bare
  #     `>` would raise from inside Comparable — the right answer for the wrong
  #     reason, with a message about an operator rather than about this change.
  #     FX is a pricing decision, not something a plan change may make.
  #   * **Different intervals.** Ten dollars a month against a hundred a year is
  #     not a cheaper plan; it is a different unit. Multiplying a monthly price by
  #     twelve to compare it with an annual one is computing money that nobody
  #     asked for, in a currency of our own invention.
  class PlanChange
    # The two timings. `:immediately` for an upgrade, `:period_end` for
    # everything else — including a change to the same price, which is not an
    # upgrade and so does not get an immediate proration.
    IMMEDIATELY = :immediately
    PERIOD_END = :period_end

    # What the processor is asked to do with the difference. `always_invoice`
    # bills it now; `none` carries nothing forward. The amount is the processor's
    # in both cases.
    ALWAYS_INVOICE = "always_invoice".freeze
    NO_PRORATION = "none".freeze

    class Error < StandardError; end

    # The two prices are quoted per different intervals, so they are not the same
    # unit and comparing them says nothing about whether the move is an upgrade.
    class IntervalMismatch < Error; end

    # The destination plan has no processor price, so there is nothing to tell the
    # processor to move the subscription onto.
    class Unpriced < Error; end

    attr_reader :from, :to

    def initialize(from:, to:)
      @from = from
      @to = to
    end

    # When the move takes effect. The one decision, and the only place a price is
    # compared.
    def timing
      ensure_comparable!
      return IMMEDIATELY if to.price > from.price

      PERIOD_END
    end

    def upgrade?
      timing == IMMEDIATELY
    end

    # A lateral move — the same plan — is neither. Refusing to call it a
    # downgrade keeps "downgrade" meaning what it says.
    def downgrade?
      ensure_comparable!
      to.price < from.price
    end

    # What the processor does about the money in between. A proration *behaviour*,
    # never an amount: the processor owns the number.
    def proration_behavior
      upgrade? ? ALWAYS_INVOICE : NO_PRORATION
    end

    # The processor's price for the plan being moved to. An upgrade is applied
    # immediately, so this is needed on the request itself; a period-end move is
    # carried out by the processor, which already knows the price.
    def to_price_id
      raise Unpriced, "plan #{to.slug} has no processor_price_id to move a subscription to" if to.processor_price_id.blank?

      to.processor_price_id
    end

    private
      # Both refusals, in one place, so a `timing`, an `upgrade?` and a
      # `downgrade?` cannot each discover a different answer. `Billing::Money#<=>` is nil
      # across currencies, which is why the currency is checked before the
      # comparison rather than by rescuing the comparison's own failure.
      def ensure_comparable!
        # Billing::Money's own error, not a second one that says the same thing: a caller
        # refusing to compare two amounts wants to catch one class whichever
        # comparison it came from.
        if from.price.currency != to.price.currency
          raise Billing::Money::CurrencyMismatchError,
            "cannot compare #{from.price} with #{to.price}: different currencies are not interchangeable"
        end

        return if from.interval == to.interval

        raise IntervalMismatch,
          "cannot compare a #{from.interval} plan with a #{to.interval} one: the prices are not the same unit"
      end
  end
end
