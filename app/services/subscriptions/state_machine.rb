module Subscriptions
  # The subscription lifecycle, as one object with named transitions.
  #
  # Everything this service knows about which subscription states exist, and which
  # may follow which, is in the `LEGAL` table below. There is no other place: no
  # controller contains a `case status` and neither does the webhook path. One
  # table means the set of *impossible* transitions is readable, which is the
  # property that actually matters and the one a pile of conditionals cannot show
  # you.
  #
  # The object is pure. It takes a from-status and a to-status and answers; it
  # never touches the database, never reads the clock and never calls the
  # processor. That is what makes the whole cross product of six froms (including
  # "nothing exists") and five tos testable as a table rather than reached through
  # five fixtures and a webhook — see test/services/subscriptions/state_machine_test.rb,
  # which asserts every legal and every illegal transition.
  #
  # ## The table is permissive, and the one refusal is the point
  #
  # Four of the five statuses may follow each other freely, including from
  # `nil` — a subscription may be born `active`, `trialing`, `past_due`, `unpaid`
  # **or `canceled`**. That looks careless and is the opposite: this service does
  # not second-guess the processor about a status, because the processor is the
  # party that bills, and a row this service "corrected" into a status the
  # processor did not report would grant entitlements nobody paid for.
  #
  # So the machine's whole job is one rule, and the rest of the lifecycle is
  # ordinary code:
  #
  # > **`canceled` is terminal. Nothing leaves it.**
  #
  # Not an `updated` that says `active`. Not a `created` that arrives after the
  # deletion that overtook it. Not a second `deleted`. That single rule is what
  # makes out-of-order delivery safe, and it is why a deletion arriving before its
  # creation is *kept* rather than dropped: the deletion creates a `canceled` row,
  # which grants nothing, and the creation that follows is then refused. Dropping
  # it instead would leave an active row — and active rows grant entitlements — for
  # a subscription the processor says is over. That is the single worst outcome
  # this table exists to make impossible.
  #
  # A status the processor uses and this service does not model is an error rather
  # than a value to guess at. `incomplete`, `incomplete_expired` and `paused` are
  # refused by the constructor, so the caller must park the delivery with a reason
  # instead of writing a row that says a subscription is `active` when the
  # processor says it is `incomplete`.
  class StateMachine
    LEGAL = {
      nil => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "trialing" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "active" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "past_due" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "unpaid" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "canceled" => { "active" => false, "trialing" => false, "past_due" => false, "unpaid" => false, "canceled" => false }
    }.freeze

    TERMINAL_REASON = "canceled_is_terminal".freeze

    attr_reader :from, :to

    def initialize(from, to)
      @from = from
      @to = to

      raise ArgumentError, "unknown target status #{to.inspect}" unless Subscription::STATUSES.include?(to)
      raise ArgumentError, "unknown from status #{from.inspect}" unless from.nil? || Subscription::STATUSES.include?(from)
    end

    def legal?
      LEGAL.fetch(from).fetch(to)
    end

    # Why a transition is refused, or nil when it is allowed.
    def reason
      return nil if legal?

      TERMINAL_REASON
    end

    # Whether applying this transition would create the row. Only a start from
    # nothing does; everything else updates a row that is already there.
    def creates?
      from.nil? && legal?
    end

    def terminal?
      Subscription::TERMINAL_STATUSES.include?(from)
    end

    def live?
      Subscription::LIVE_STATUSES.include?(to)
    end
  end
end
