# A billing customer: something identity knows about, which billing can charge.
#
# This is billing's own row, not the person. `owner` is a reference across a
# service boundary — identity's uuid, stored as a uuid, with no foreign key and
# no Active Record association, because there is no `User` class in this process
# to associate to. The two columns are the whole contract with identity, and
# OWNER_TYPES is the list of entities billing knows how to bill.
#
# The uniqueness rule is one customer per (owner, processor). An owner can
# legitimately have a customer at two processors, and a processor migration
# must not collide on the way there.
#
# `processor` is a plain string column with an inclusion validation and a
# CHECK constraint, not a Rails `enum`. An enum raises ArgumentError the moment
# an unknown value is assigned, which at an HTTP boundary is a 500 for
# something the client got wrong; a validation is a 422 that names the field.
# The database still refuses any value outside the set, so bypassing the model
# does not get a row that the model would not have written.
class Customer < ApplicationRecord
  # identity's entities that can be billed. Adding one is a change to what
  # billing believes the platform is made of, which is why it is a constant here
  # rather than a free-form string.
  OWNER_TYPES = %w[User Account].freeze

  # The processors this service can talk to. v0 stores the name only: this
  # packet makes no Stripe call, so `processor_customer_id` stays null.
  PROCESSORS = %w[stripe].freeze

  # `allow_nil` on the inclusions for the same reason as Plan: a missing value
  # is a blank, which is one problem with one fix, not two.
  validates :owner_type, presence: true
  validates :owner_type, inclusion: { in: OWNER_TYPES }, allow_nil: true
  validates :owner_id, presence: true
  validates :processor, presence: true
  validates :processor, inclusion: { in: PROCESSORS }, allow_nil: true
  validates :email, presence: false
  validate :owner_id_is_a_uuid
  validate :email_is_deliverable
  validate :metadata_is_an_object

  # `:taken` is what makes a duplicate a 409 rather than a 422: the request was
  # well-formed, it just collides with something that already exists.
  validates :processor, uniqueness: { scope: %i[owner_type owner_id] }

  # **A second row may not claim one `cus_`.** The database says so
  # (`customers_processor_customer_id_idx`, billing-13); this is what turns the
  # collision into a *named* answer for a client.
  #
  # `Subscriptions::Lifecycle#customer` resolves a delivery by this column with
  # `find_by`, so two rows claiming one id is a question with two answers and a
  # delivery about one account's subscription billed to whichever row the planner
  # reached first. With the index alone the answer is a 409 whose body says "That
  # record already exists." and names no field; with this the 409 names
  # `processor_customer_id`, which is the one column of this resource a client can
  # move onto somebody else's.
  #
  # `allow_nil` because the column is nullable on purpose: a customer created
  # through `/v1` has no `cus_` until its first subscription tells this service
  # what the processor calls it, and many rows are legitimately in that state at
  # once. So the rule is "a value here is unique", not "this column is unique" —
  # the same reading the index's partial predicate states, and the reason that
  # index is partial rather than a bare `unique`.
  validates :processor_customer_id, uniqueness: true, allow_nil: true

  # **This account's customers, and nobody else's.**
  #
  # The tenancy key on a customer is `owner_type`/`owner_id`, and a customer is
  # only in scope when that pair names an `Account` this caller is acting for.
  # `owner_type: "User"` rows are deliberately **excluded** rather than matched on
  # `owner_id` alone: which account a user belongs to is identity's fact and no
  # event carrying it is in this build's `consumes`, so a user-owned customer has
  # no account to scope by and must not be handed to a caller who guessed the uuid.
  #
  # The scope and not a `where` at each call site, because the shape that scoping
  # arrives in is `scope :for_account, ->(id) { … }` and there are three customer
  # reads on `/v1` that must all agree; a hand-written `where` at each is three
  # chances to write one of them down differently.
  scope :for_account, ->(account_id) {
    where(owner_type: "Account", owner_id: account_id)
  }

  before_validation :normalize_metadata

  # The wire shape, and the outbox payload: one representation, so an event and
  # a response cannot disagree about what a customer is.
  def as_json(*)
    {
      "id" => id,
      "owner" => { "type" => owner_type, "id" => owner_id },
      "processor" => processor,
      "processor_customer_id" => processor_customer_id,
      "email" => email,
      "metadata" => metadata,
      "created_at" => created_at&.utc&.iso8601,
      "updated_at" => updated_at&.utc&.iso8601
    }
  end

  after_create :publish_created

  private
    def publish_created
      OutboxEvent.publish!(
        type: "billing.customer.created",
        subject: id,
        data: as_json
      )
    end

    # There is deliberately no `billing.customer.updated`. The event catalog in
    # core has no row for it, and core's suite fails a manifest that declares a
    # type the catalog does not list. The API can still change a customer's
    # email; nothing downstream is told. That gap belongs to whoever owns the
    # catalog, not to a worker inventing a row.

    # jsonb is shape-checked by the column, so a scalar that reached the
    # attribute has to be refused here rather than stored and discovered later.
    # A null is not a scalar: it means "not provided", and the wire shape
    # promises an object, so it is normalised to the empty one.
    def metadata_is_an_object
      return if metadata.nil? || metadata.is_a?(Hash)

      errors.add(:metadata, :invalid_format, message: "is not an object")
    end

    # These two add an explicit `:invalid_format` error rather than using
    # `validates format:`, which reports a failure as the generic `:invalid` and
    # would tell a client "invalid" where it could have told it which shape was
    # expected. `allow_nil` behaviour is explicit for the same reason: a missing
    # email is a blank, which is a different problem with a different fix.
    def owner_id_is_a_uuid
      return if owner_id.blank? || Identifiers::UUID.match?(owner_id)

      errors.add(:owner_id, :invalid_format, message: "is not a uuid")
    end

    def email_is_deliverable
      return if email.blank? || URI::MailTo::EMAIL_REGEXP.match?(email)

      errors.add(:email, :invalid_format, message: "is not a deliverable address")
    end

    def normalize_metadata
      self.metadata = {} if metadata.nil?
    end
end
