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
  STATUSES = %w[trialing active past_due canceled unpaid].freeze

  LIVE_STATUSES = (STATUSES - %w[canceled]).freeze
  TERMINAL_STATUSES = %w[canceled].freeze

  ACTIONABLE_STATUSES = %w[trialing active past_due].freeze

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
