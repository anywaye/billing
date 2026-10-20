# A plan: what can be bought, at what price, on what cadence.
#
# The only way an amount enters this model is `price=`, and it takes a `Billing::Money`.
# `amount_cents` and `currency` are the two columns that amount is stored in,
# and nothing else writes them: the controller parses a request into a `Billing::Money`
# (or refuses it), the column type and a CHECK constraint refuse a negative or
# a non-integer, and `as_json` reads it back out through `price`. There is no
# code path where a Float carries a price (AGENTS.md, Billing::Money).
#
# `interval` is a plain string with an inclusion validation and a CHECK
# constraint rather than a Rails `enum`, for the reason given on Customer: an
# enum raises ArgumentError on an unknown value, and at an HTTP boundary that
# is a 500 for something the client got wrong.
class Plan < ApplicationRecord
  INTERVALS = %w[month year one_time].freeze

  # kebab-case, so a slug is always one URL segment with nothing to escape.
  SLUG_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  # What a plan grants. An object with at most these two members, so a reader never
  # has to ask whether a key it does not know is one it should honour: `features` is
  # a list of things switched on, `limits` is a number for each of them.
  ENTITLEMENT_KEYS = %w[features limits].freeze

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  # **A second plan may not claim one `price_`.** The database says so
  # (`plans_processor_price_id_idx`, billing-13); this is what turns the collision
  # into a *named* answer for a client.
  #
  # `Subscriptions::Lifecycle#plan` resolves a delivery by this column with
  # `find_by`, so a subscription is billed against whichever plan claimed the id.
  # Two plans on one `price_` and one of them is billed at an amount this service
  # never agreed to with the customer, and `billing.subscription.started` carries
  # that plan's currency and says nothing about the one that was intended — so the
  # wrong amount is not only charged but published. With the index alone that is a
  # 409 naming no field; with this it names `processor_price_id`.
  #
  # `allow_nil` because a plan is written through `/v1` before it is ever put on
  # sale at the processor, and many plans are legitimately unsold at once. The rule
  # is "a value here is unique", not "this column is unique" — the same reading the
  # index's partial predicate states.
  validates :processor_price_id, uniqueness: true, allow_nil: true

  validates :interval, presence: true
  # `allow_nil` so that a missing interval is reported once, as a blank, rather
  # than twice — once as a blank and once as "not one of the allowed values".
  validates :interval, inclusion: { in: INTERVALS }, allow_nil: true
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :trial_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :slug_is_kebab_case
  validate :currency_is_iso_4217
  validate :entitlements_are_a_closed_object

  before_validation :normalize_currency
  before_validation :normalize_entitlements

  # The amount, as the value object. This is the read side of the money rule:
  # a caller that wants to do arithmetic on a price gets a `Billing::Money`, never the
  # raw integer, so a currency cannot be dropped by accident.
  def price
    Billing::Money.new(amount_cents, currency)
  end

  # A plan is **platform catalogue and not tenant data**, and that is the reason
  # `V1::PlansController` resolves a plan by slug or uuid with no account filter —
  # while every customer and subscription query on `/v1` carries one.
  #
  # It is worth being explicit about why the two are different, because the matrix
  # in `test/contract/tenant_isolation_matrix_test.rb` calls a plan tenant data
  # ("a plan is the catalogue of what an account may buy") and this comment is where
  # that is resolved. A plan has **no `account_id` column**: a plan is what an
  # account may buy, not what an account owns, so every account reads the same rows.
  # `test/support/two_accounts.rb` deliberately builds ONE plan shared by both
  # accounts, and `subscriptions_live_account_plan_idx` is keyed on
  # `(account_id, plan_id)` precisely because the plan is shared and the account is
  # not — a fixture that gave each account its own plan could not tell a correct
  # index from a missing `account_id`.
  #
  # **What this does NOT settle is who may write the catalogue.** `POST /v1/plans`
  # and `PATCH /v1/plans/{id}` change what *every* account is offered and at what
  # price, so they are a capability question and core's answer is `scopes`, not
  # `account_id`. No client in this build holds a billing scope, so no scope check
  # is enforced and any authenticated caller can currently write the catalogue.
  # That is a recorded gap (`README.md`, "Known gaps") rather than a decision, and
  # `Principal#scopes` is the place it is closed.

  # The write side. Refuses anything that is not a `Billing::Money`, because the whole
  # point of the type is that a bare integer has no currency and a Float has no
  # exact value. A caller with a raw pair must build the Billing::Money itself.
  def price=(money)
    unless money.is_a?(Billing::Money)
      raise Billing::Money::InvalidAmountError, "price must be a Billing::Money, got #{money.class}"
    end

    self.amount_cents = money.minor_units
    self.currency = money.currency
    money
  end

  # The wire shape, and the outbox payload: one representation, so an event and
  # a response cannot disagree about what a plan costs.
  def as_json(*)
    {
      "id" => id,
      "name" => name,
      "slug" => slug,
      "processor_product_id" => processor_product_id,
      "processor_price_id" => processor_price_id,
      "price" => price.to_h,
      "interval" => interval,
      "trial_days" => trial_days,
      "entitlements" => entitlements,
      "active" => active,
      "created_at" => created_at&.utc&.iso8601,
      "updated_at" => updated_at&.utc&.iso8601
    }
  end

  after_create :publish_created
  after_update :publish_updated

  private
    def publish_created
      OutboxEvent.publish!(type: "billing.plan.created", subject: id, data: as_json)
    end

    # Only when something actually changed. A PATCH that sets a field to the
    # value it already holds is not a state change, and an event that says
    # otherwise teaches a consumer to expect updates that carry no update.
    def publish_updated
      return unless saved_changes?

      OutboxEvent.publish!(type: "billing.plan.updated", subject: id, data: as_json)
    end

    # Added as an explicit `:invalid_format` rather than through
    # `validates format:`, which reports a failure as the generic `:invalid`.
    # A slug that is "Pro Monthly" and a currency that is "dollars" are both
    # "here is the shape we accept", and the client is told the shape.
    def slug_is_kebab_case
      return if slug.blank? || SLUG_PATTERN.match?(slug)

      errors.add(:slug, :invalid_format, message: "must be kebab-case")
    end

    # ISO 4217 shape, not the list of live codes — the same reasoning Billing::Money
    # gives: a hand-maintained list of 180 currencies is a liability in a
    # payment system, and an unfamiliar code should not be refused before the
    # catalogue lands. Upcased first, so `usd` is accepted and stored as `USD`;
    # the column is `varchar(3)`, and a lowercase code that reached the
    # database anyway is caught by the length and shape here.
    def currency_is_iso_4217
      return if currency.blank? || Billing::Money::CURRENCY_FORMAT.match?(currency)

      errors.add(:currency, :invalid_format, message: "is not an ISO 4217 code")
    end

    def normalize_currency
      self.currency = currency.to_s.strip.upcase if currency.present?
    end

    # A nil becomes the empty object rather than staying null: the wire shape
    # promises an object, and a null would be a second shape every reader has to
    # handle.
    def normalize_entitlements
      self.entitlements = {} if entitlements.nil?
    end

    # The shape is closed here, at the only place a plan is written, rather than
    # guessed at by each reader. `features: "dashboards"` is the case that matters:
    # `Array("dashboards")` renders as `["dashboards"]`, so the mistake is invisible
    # in a response and only shows up when somebody writes `features.first.end_with?`
    # on a subscription that is granting the wrong thing.
    #
    # One `:invalid_format` error for the whole object rather than one per member:
    # a client that sent `features` as a string has one mistake, and three errors
    # saying the same thing is three things to fix.
    def entitlements_are_a_closed_object
      return if entitlements.nil?
      return add_entitlements_error unless entitlements.is_a?(Hash)
      return add_entitlements_error unless (entitlements.keys - ENTITLEMENT_KEYS).empty?
      return if features_are_a_list_of_names? && limits_are_counts?

      add_entitlements_error
    end

    def add_entitlements_error
      errors.add(:entitlements, :invalid_format, message: "must be an object with `features` and `limits`")
    end

    def features_are_a_list_of_names?
      features = entitlements["features"]
      return true if features.nil?
      return false unless features.is_a?(Array)

      features.all? { |feature| feature.is_a?(String) && feature.strip.present? }
    end

    # Counts, not amounts. There is no `Billing::Money` here on purpose: a limit is how many
    # of something, and putting it in a currency would be a category error this
    # service has already made the mistake of avoiding everywhere else.
    def limits_are_counts?
      limits = entitlements["limits"]
      return true if limits.nil?
      return false unless limits.is_a?(Hash)

      limits.values.all? { |limit| limit.is_a?(Integer) && limit >= 0 }
    end
end
