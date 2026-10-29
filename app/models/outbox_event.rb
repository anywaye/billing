# One event, written in the same transaction as the state change it describes.
#
# The row is the event. Nothing here publishes to anything: a dispatcher that
# claims the unpublished rows and hands them to a transport is a later packet,
# because anywaye has no broker wired up and adding a queue is a dependency
# decision this packet does not get to make (AGENTS.md). What this packet does
# fix is the part that is expensive to get wrong later: the envelope, the
# grammar, and the transaction.
#
# The row's primary key doubles as the envelope's `id`, which core defines as
# the dedupe key. A re-emission is a new row and therefore a new id, so a
# consumer that has seen an event can always tell it from the next one.
class OutboxEvent < ApplicationRecord
  SERVICE = "billing"

  TYPES = %w[
    billing.customer.created
    billing.payment.failed
    billing.payment.succeeded
    billing.plan.created
    billing.plan.updated
    billing.subscription.canceled
    billing.subscription.started
    billing.subscription.updated
  ].freeze

  TYPE_PATTERN = /\A[a-z][a-z0-9]*(-[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\.[a-z][a-z0-9]*(_[a-z0-9]+)*\z/

  SUBJECT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]*\z/

  UUID_PATTERN = Identifiers::UUID

  TYPE_LENGTH = (5..120).freeze
  SUBJECT_LENGTH = (1..200).freeze

  validates :event_type, presence: true, inclusion: { in: TYPES }, length: { in: TYPE_LENGTH }
  validates :subject, presence: true, length: { in: SUBJECT_LENGTH }
  validates :source, presence: true, inclusion: { in: [ SERVICE ] }
  validates :time, presence: true
  validate :subject_is_an_entity_id
  validate :data_is_an_object

  scope :unpublished, -> { where(published_at: nil) }
  scope :oldest_first, -> { order(:created_at, :id) }

  scope :for_processor_event, ->(processor_event_id) {
    where("data ->> 'processor_event_id' = ?", processor_event_id)
  }

  # Writes one event. Called from `after_create`/`after_update` on the record it
  # describes, which is inside that record's transaction — so the event and the
  # change it announces commit together or not at all. The row's id is the
  # envelope's id, so nothing is generated twice.
  #
  # The keyword is `type` because that is what the envelope calls it; the column
  # is `event_type` because `type` is reserved by Active Record.
  #
  # `time` is when the state change happened, and it is a keyword rather than
  # always-`Time.current` because not every state change is made by this process.
  # A webhook's event describes something Stripe did seconds or days ago, and
  # stamping it with the moment the row was written would make an out-of-order
  # delivery undetectable: every event would appear to have happened in the order
  # it arrived. The default keeps the model-callback path exactly as it was.
  def self.publish!(type:, subject:, data:, time: Time.current)
    create!(
      event_type: type,
      source: SERVICE,
      subject: subject,
      time: time,
      data: data
    )
  end

  # The envelope as core defines it: CloudEvents 1.0 attribute names, anywaye's
  # required subset, and nothing else — `additionalProperties` is false, so an
  # attribute that is not in this method is an attribute that does not exist.
  def to_envelope
    {
      "specversion" => "1.0",
      "id" => id,
      "type" => event_type,
      "source" => source,
      "subject" => subject,
      "time" => time.utc.iso8601,
      "data" => data
    }
  end

  private
    # The subject is the entity the event is about, so it has to be able to be
    # an identifier and nothing else. A subject that carried transport metadata
    # — a trace id, a retry count, a sentence — would be a place for envelope
    # and header state to disagree, which core's schema closes off with
    # `additionalProperties: false` for attributes and a strict pattern here.
    def subject_is_an_entity_id
      return if SUBJECT_PATTERN.match?(subject.to_s)

      errors.add(:subject, :invalid_format, message: "is not an entity identifier")
    end

    def data_is_an_object
      return if data.nil? || data.is_a?(Hash)

      errors.add(:data, :invalid_format, message: "is not an object")
    end
end
