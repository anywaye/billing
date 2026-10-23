# A subscription: one account, on one plan, for one billing period at a time.
#
# The whole model turns on one fact about it: **this service never decides what a
# subscription's status is.** The processor does, it says so on a signed webhook,
# and this table is the record of what it said. Nothing here writes a status from
# a anywaye request — cancelling and changing a plan both call the processor and
# wait for the event that comes back. That is why there is no `after_create` or
# `after_update` publishing an event: the only writer of this row is
# `Subscriptions::Lifecycle`, and it is the only thing that emits a
# subscription's events, in the transaction that changed the row.
#
# The uniqueness rules are two, and the second is about a set of statuses:
#
#   * `processor_subscription_id` is UNIQUE, and that index is the resolution
#     mechanism rather than a query aid. Every event about a subscription is
#     looked up by the processor's id, so two rows for one processor subscription
#     would be two answers to one question.
#   * `(account_id, plan_id)` is UNIQUE **for live subscriptions only**. A
#     canceled subscription is history: a customer who cancels and comes back
#     has to be able to subscribe to the same plan again, and an index that did
#     not exclude `canceled` would make that impossible for the second time.
#
# `status` is a plain string with an inclusion validation and a CHECK constraint,
# for the reason `Customer#processor` and `Plan#interval` are: a Rails `enum`
# raises ArgumentError the moment an unknown value is assigned, and at an HTTP
# boundary that is a 500 for something the caller got wrong.
class Subscription < ApplicationRecord
  # The statuses this service stores. Chosen from what the processor actually
  # sends for a flat plan bought through Checkout:
  #
  #   trialing   — in a trial, has not charged yet
  #   active     — billing normally
  #   past_due   — a charge failed, the grace period is running
  #   unpaid     — collection was given up on; the processor will cancel it
  #   canceled   — over
  #
  # The processor also has `incomplete`, `incomplete_expired` and `paused`, and
  # this list is closed on purpose. A status outside it is *refused* by the
  # lifecycle with the delivery recorded, rather than coerced into one of these
  # five: a row that says `active` for a subscription the processor calls
  # `incomplete` grants entitlements nobody has paid for, and the refusal is a
  # row somebody can find. The other direction is harmless — a status this
  # service does not model is not one it can have learned. Recorded as a
  # decision in anywaye.yml.
  STATUSES = %w[trialing active past_due canceled unpaid].freeze

  # Everything that is not over. `canceled` is the only terminal status, and that
  # single fact is what the live-uniqueness index and the state machine are both
  # built on.
  LIVE_STATUSES = (STATUSES - %w[canceled]).freeze
  TERMINAL_STATUSES = %w[canceled].freeze

  # The statuses a caller can still ask the processor to do something about:
  # cancelling one, or moving it to another plan.
  #
  # `unpaid` is excluded from both, and the reason is the same: the processor has
  # stopped collecting and is about to cancel the subscription itself, so there is
  # nothing left to ask. It is still `LIVE` — it still grants entitlements, because
  # the grace period is a product decision and not this service's to take away.
  #
  # One set rather than two because the two actions have the same boundary, and two
  # sets would be two lists to keep in step.
  ACTIONABLE_STATUSES = %w[trialing active past_due].freeze

  # The owner types a subscription can be billed to. A `User`-owned customer
  # cannot hold one: which account a user belongs to is identity's fact and no
  # event carrying it is in this build's `consumes`.
  BILLABLE_OWNER_TYPE = "Account"

  belongs_to :customer
  belongs_to :plan

  validates :processor_subscription_id, presence: true, uniqueness: true
  validates :account_id, presence: true
  validates :status, presence: true
  validates :status, inclusion: { in: STATUSES }, allow_nil: true
  validate :account_is_the_customers_owner

  scope :live, -> { where.not(status: TERMINAL_STATUSES) }
  scope :canceled, -> { where(status: TERMINAL_STATUSES) }

  # **This account's subscriptions, and nobody else's.**
  #
  # `account_id` is a real column and is denormalised from the customer's owner
  # precisely so that a query can be scoped by it without joining — see
  # `account_is_the_customers_owner` for why it cannot drift, and
  # `subscriptions_live_account_plan_idx` for the uniqueness it is keyed on.
  #
  # This is the scope that makes `POST /v1/subscriptions/{id}/cancel` safe. Every
  # read on `/v1` reaches a subscription through here, so a uuid naming another
  # account's row resolves to `nil` and the action answers **404** — the same answer
  # a uuid naming nothing gets, because a 403 would tell a caller walking ids which
  # ones exist. Absence, never refusal; see `AuthenticatesPrincipal`.
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  def canceled?
    TERMINAL_STATUSES.include?(status)
  end

  def live?
    LIVE_STATUSES.include?(status)
  end

  # Whether this subscription's plan's features are granted right now. A canceled
  # subscription grants nothing, which is the only answer here that is a
  # decision rather than a copy of the plan.
  def grants_entitlements?
    live?
  end

  # The wire shape. One representation, so a response and a read agree about what
  # a subscription is.
  #
  # `plan_slug` is here because a caller reading a subscription almost always
  # wants to show the plan's name and a uuid cannot; it is derived from the
  # association, never stored, so it cannot go stale. `last_processor_event_at`
  # is deliberately absent: it is the service's own ordering bookkeeping, not a
  # fact about the subscription, and a client has no use for it.
  def as_json(*)
    {
      "id" => id,
      "account_id" => account_id,
      "plan_id" => plan_id,
      "plan_slug" => plan&.slug,
      "customer_id" => customer_id,
      "processor_subscription_id" => processor_subscription_id,
      "status" => status,
      "current_period_start" => current_period_start&.utc&.iso8601,
      "current_period_end" => current_period_end&.utc&.iso8601,
      "cancel_at_period_end" => cancel_at_period_end,
      "canceled_at" => canceled_at&.utc&.iso8601,
      "created_at" => created_at&.utc&.iso8601,
      "updated_at" => updated_at&.utc&.iso8601
    }
  end

  private
    # There is no `account_id` shape validation, deliberately. The column is
    # `uuid`, so Active Record casts anything that is not one to nil before a
    # validation ever sees it, and the presence validation is what reports it. A
    # shape check here would be unreachable code that reads as if it were doing
    # something. (`Customer` has such a check and it is equally unreachable —
    # noted, not changed: it is not this packet's model to refactor.)

    # The account is the customer's owner, frozen here at creation. Denormalising
    # it is what lets `billing.subscription.started` carry `account_id` — a
    # required field of core's payload schema — and what the live-uniqueness
    # index is keyed on, and it cannot drift: a customer's owner is part of the
    # key `customers` makes unique, so moving one is a delete and a create.
    def account_is_the_customers_owner
      return if customer.blank? || account_id.blank?

      if customer.owner_type != BILLABLE_OWNER_TYPE
        errors.add(:customer, :invalid_format, message: "is not an account, and a subscription is billed to an account")
      elsif customer.owner_id != account_id
        errors.add(:account_id, :invalid_format, message: "is not this customer's account")
      end
    end
end
