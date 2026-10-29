# A processor's event, as received: the raw body, verified by signature, stored
# before anything tries to interpret it, and processed at most once.
#
# The whole point of this table is that a replay is a non-event. Stripe delivers
# at-least-once and retries on any non-2xx, so the same event id will arrive
# again — immediately, or a day later — and the second arrival must not produce a
# second `payment.succeeded` with a second envelope id. `stripe_event_id` is
# UNIQUE for exactly that reason, and `ingest` turns the resulting conflict back
# into a lookup.
#
# What lives in `error` is a terminal outcome, not an error in the HTTP sense:
# a row with `processed_at` set and an `ignored:` prefix was understood and
# deliberately not acted on, and a `failed:` prefix means the row is parked for
# a human. Both answer 200, because a processor that retries a decision this
# service has already made will retry it until Stripe gives up, and the retry
# accomplishes nothing.
class ProcessorWebhook < ApplicationRecord
  MAX_ERROR_LENGTH = 1_000

  PROCESSORS = %w[stripe].freeze

  IGNORED_PREFIX = "ignored:"
  FAILED_PREFIX = "failed:"

  self.inheritance_column = nil

  validates :processor, presence: true, inclusion: { in: PROCESSORS }
  validates :stripe_event_id, presence: true
  validates :type, presence: true
  validates :payload, presence: true

  # Records the event under its processor's own id, or returns the row already
  # stored under it.
  #
  # The `rescue` is not defensive noise. `find_or_create_by!` is a
  # read-then-write, and two deliveries of the same event id can both miss the
  # read; the unique index is what settles it, and the loser has to come back
  # with the winner's row instead of raising. A 500 here would tell Stripe to
  # redeliver, which is the one thing that is guaranteed to race again.
  def self.ingest(processor:, event_id:, type:, payload:)
    processor = processor.to_s
    raise ArgumentError, "unknown processor: #{processor}" unless PROCESSORS.include?(processor)
    raise ArgumentError, "event id is required" if event_id.blank?
    raise ArgumentError, "event type is required" if type.blank?

    find_or_create_by!(stripe_event_id: event_id) do |webhook|
      webhook.processor = processor
      webhook.type = type
      webhook.payload = payload
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(stripe_event_id: event_id)
  end

  def handled?
    processed_at.present?
  end

  def ignored?
    error.to_s.start_with?(IGNORED_PREFIX)
  end

  def failed?
    error.to_s.start_with?(FAILED_PREFIX)
  end

  # The event was handled: it became a anywaye event, and there is nothing to
  # look at. `processed_at` is the receipt.
  def handled!
    mark_processed!(error: nil)
  end

  # The event was understood and deliberately not acted on. The reason is part
  # of the record so that "we ignored it" is a query rather than a guess.
  def ignore!(reason)
    mark_processed!(error: "#{IGNORED_PREFIX}#{reason}")
  end

  # The event could not be processed. Recorded with the class and the message,
  # because the identifier needed to find the failing row belongs in the row.
  def fail!(exception)
    mark_processed!(error: "#{FAILED_PREFIX}#{exception.class}: #{exception.message}".truncate(MAX_ERROR_LENGTH))
  end

  private
    def mark_processed!(error:)
      update!(processed_at: Time.current, error: error)
    end
end
