# The outbox publisher: billing's committed rows onto the fleet's bus.
#
# billing has written `outbox_events` since billing-02 — a domain change and its
# event commit together or not at all — and until this packet nothing moved them
# anywhere. `published_at` was always null and `attempts` always zero. This
# namespace is the other half of the outbox's promise: rows *leave the table*.
#
# ## What is here and what is deliberately not
#
# The claim (`select ... for update skip locked`), the envelope grammar and the
# publish pass are **not** here: they are `Anywaye::Outbox`, the fleet's shared
# gem, vendored at `vendor/anywaye` (see `VENDORED.md`). A second claim mechanism
# in billing would be a second answer to a question the whole fleet asks once.
# What a service owes on top of the gem is exactly the three things the gem says
# it does not own:
#
#   * **the transport** — `NatsPublisher`. One method: put this envelope on the
#     bus, and return only once the broker has it.
#   * **the loop** — `Relay`. A fixed one-second poll, tied to the process.
#   * **the wiring** — `config/initializers/outbox_relay.rb`. Starts on
#     `NATS_URL`, and does not start without it.
#
# ## The three decisions identity documented, matched rather than re-derived
#
# * **Batch 100.** The gem's `DEFAULT_BATCH_SIZE`, from core's 100-500 range at
#   the low end: a larger transaction holds row locks longer, a smaller one costs
#   more round trips.
# * **A fixed one-second poll, not an exponential backoff.** A backoff that
#   grows while idle leaves a newly created subscription's event sitting
#   unpublished for minutes, and a fresh event is the common case. The gem's
#   *per-row* backoff (a row that failed once waits a second, then two) delays
#   only rows that have already been tried; a row at zero attempts is due
#   immediately, which is why a fixed poll and a per-row backoff coexist here
#   without contradicting each other.
# * **`NoopPublisher` exists in identity and is never wired, and neither is
#   anything like it here.** Marking every event published and draining the
#   outbox into nowhere is worse than the honest accumulation an unconfigured
#   broker produces. With no `NATS_URL` the rows simply stay, and the boot log
#   says so.
#
# ## The subject is the event type
#
# core's `docs/event-outbox.md`: "No mapping table, no prefix rewriting." A row
# whose type is `billing.subscription.started` is published on the subject
# `billing.subscription.started` and nothing else — which is what the fleet's
# `billing.>` stream filter matches. The envelope's *`subject` attribute* is a
# different field: it is the entity the event is about (the row's `subject`
# column, a anywaye uuid), and it goes in the envelope, not on the wire.
module Outbox
  class Error < StandardError; end

  # A `NATS_URL` that does not parse. Refused at boot, where an operator reads
  # it: a deployment that believes it has a bus and does not is the worse of the
  # two states, and "the broker is down" is a failure at the first event where
  # nobody is looking. A broker that is *down* is not this error — see
  # `NatsPublisher`, which treats that as an outage rather than a typo.
  class ConfigurationError < Error; end
end
