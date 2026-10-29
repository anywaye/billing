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
  OWNER_TYPES = %w[User Account].freeze

  PROCESSORS = %w[stripe].freeze

  validates :owner_type, presence: true
  validates :owner_type, inclusion: { in: OWNER_TYPES }, allow_nil: true
  validates :owner_id, presence: true
  validates :processor, presence: true
  validates :processor, inclusion: { in: PROCESSORS }, allow_nil: true
  validates :email, presence: false
  validate :owner_id_is_a_uuid
  validate :email_is_deliverable
  validate :metadata_is_an_object

  validates :processor, uniqueness: { scope: %i[owner_type owner_id] }

  validates :processor_customer_id, uniqueness: true, allow_nil: true

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
