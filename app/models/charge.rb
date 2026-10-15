# A charge: what a customer was charged, recorded for the receipt.
#
# This is billing's own record of a payment, recorded from what the processor's
# signed webhook said. It is not the processor's record — there is no
# `Pay::Charge` row here any more (the `pay` gem and its tables are gone,
# `20261015120000_drop_pay_tables.rb`) — and there is nothing to reconcile
# against: this row IS the service's answer to "what did this customer pay",
# in a shape a receipt can render. The processor's own id for the charge is
# `processor_charge_id`, and it is the join key.
#
# The whole model turns on one fact about it: **a charge is recorded when a
# payment succeeds, and never when it fails or is pending.** The processor
# says so on a signed webhook, and this table is the record of what it said.
# There is no code path that writes a charge from a cafaye request — a charge
# is a fact about money that moved, and only the party that moved it can say
# so.
#
# The uniqueness rule is one: `processor_charge_id` is UNIQUE, and that index
# is the resolution mechanism rather than a query aid. Every event about a
# charge is looked up by the processor's id, so two rows for one processor
# charge would be two answers to one question — and a customer would be
# charged twice on paper.
#
# `amount` is an integer of minor units and `currency` is an ISO 4217 code,
# for the reason `plans.amount_cents` and `plans.currency` are: money is integer
# minor units and never a Float (AGENTS.md, Money).
class Charge < ApplicationRecord
  belongs_to :customer
  belongs_to :subscription, optional: true

  validates :account_id, presence: true
  validates :processor_charge_id, presence: true, uniqueness: true
  validates :amount, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :description, presence: true
  validates :paid_at, presence: true
  validate :currency_is_iso_4217

  # **This account's charges, and nobody else's.**
  #
  # `account_id` is a real column, denormalised from the resolved customer or
  # subscription at recording time, so that a query can be scoped by it
  # without joining — the same reason `subscriptions.account_id` is
  # denormalised.
  #
  # This is the scope that makes `GET /v1/charges/{id}` safe. Every read on
  # `/v1` reaches a charge through here, so a uuid naming another account's
  # row resolves to `nil` and the action answers **404** — the same answer a
  # uuid naming nothing gets, because a 403 would tell a caller walking ids
  # which ones exist. Absence, never refusal; see `AuthenticatesPrincipal`.
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  # The wire shape. One representation, so a response and a read agree about
  # what a charge is.
  def as_json(*)
    {
      "id" => id,
      "account_id" => account_id,
      "customer_id" => customer_id,
      "subscription_id" => subscription_id,
      "processor_charge_id" => processor_charge_id,
      "amount" => amount,
      "currency" => currency,
      "description" => description,
      "paid_at" => paid_at&.utc&.iso8601,
      "created_at" => created_at&.utc&.iso8601,
      "updated_at" => updated_at&.utc&.iso8601
    }
  end

  private
    # ISO 4217 shape, not the list of live codes — the same reasoning `Plan`
    # gives: a hand-maintained list of 180 currencies is a liability in a
    # payment system, and an unfamiliar code should not be refused before the
    # catalogue lands.
    def currency_is_iso_4217
      return if currency.blank? || Money::CURRENCY_FORMAT.match?(currency)

      errors.add(:currency, :invalid_format, message: "is not an ISO 4217 code")
    end
end
