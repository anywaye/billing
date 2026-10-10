# frozen_string_literal: true

require "cafaye/outbox/envelope"
require "cafaye/outbox/pg_connection"
require "cafaye/outbox/active_record_connection"
require "cafaye/outbox/writer"
require "cafaye/outbox/publisher"

module Cafaye
  # The transactional outbox.
  #
  # One table, written in the same transaction as the state change it describes,
  # and a loop that moves the committed rows to a transport. Both halves are
  # here because both halves are the same decision: a domain write and its event
  # must not be able to disagree. Publishing first and writing after can both
  # ship, and neither is acceptable in a system where billing depends on
  # identity.
  #
  # The contract this implements is core's, in `docs/event-outbox.md` and
  # `schemas/event-envelope.schema.json`. `db/outbox_events.sql` is core's
  # column list, and a service owns the table in its own repository and its own
  # migration.
  #
  # ## What this is not
  #
  # It is not a bus client. It has no NATS gem, no Redis gem and no queue
  # dependency, because the transport is the one decision that belongs to the
  # service: `courier` and `identity` disagree about it, and a shared library
  # that picked would be a shared library that had picked for them. A service
  # supplies one callable and gets at-least-once delivery.
  #
  # ## Transactional by refusal
  #
  # `publish!` raises `NotInTransaction` outside a transaction. That is the
  # design's whole enforcement: an event written outside the transaction that
  # wrote the state it describes is the bug this table exists to prevent, and a
  # default that permits it is a default every service eventually forgets.
  module Outbox
    # The reference DDL, as a constant rather than as a file read at runtime.
    #
    # `db/outbox_events.sql` is the same bytes and is what a service copies into
    # its own migration; a test asserts the two are byte-identical, so the file is
    # the documented artifact and this is the one the library and its suite use. A
    # gem that read its own `db/` at runtime breaks the moment it is vendored, or
    # installed with a different file list, and the failure would be
    # `Errno::ENOENT` inside a publisher loop at three in the morning.
    # `db/outbox_events.sql`, resolved from `lib/cafaye/`. Two levels up is the
    # repository root, and the first version of this constant went up three and
    # found a `db/` one directory above the repository, which is a sentence
    # nobody wants to read in a stack trace from a publisher loop.
    DDL_PATH = File.expand_path("../../db/outbox_events.sql", __dir__)

    module_function

    # The reference DDL, for a service that wants to read it rather than copy
    # it — a migration generator, a contract test, a schema linter. Raises rather
    # than returning a partial answer if the file is missing from an install,
    # which is a packaging bug this gem would rather surface loudly.
    def ddl
      File.read(DDL_PATH)
    end

    # A publisher for `deliverer`, on `connection`.
    #
    #   Cafaye::Outbox.publisher(connection: connection) { |envelope| nats.publish(envelope) }
    def publisher(connection:, clock: -> { Time.now }, logger: nil, **options, &deliverer)
      Publisher.new(connection: connection, clock: clock, logger: logger, deliverer: deliverer, **options)
    end
  end
end
