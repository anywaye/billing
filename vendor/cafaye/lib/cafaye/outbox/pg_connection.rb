# frozen_string_literal: true

require "pg"
require "json"

module Cafaye
  module Outbox
    # The outbox table, over a raw `PG::Connection`.
    #
    # This is the seam that makes the transactional guarantee testable and
    # portable. The writer needs three things from a connection — "are you in a
    # transaction", "insert this row", "give me these statements" — and the
    # first one is the one that matters. Depending on Active Record instead would
    # make a non-Rails service inherit an ORM to move one row, and would make
    # the rollback guarantee untestable outside Rails.
    #
    # Every statement goes through `exec_params`, never string interpolation. The
    # only interpolated SQL here is the `quote_ident` for a database name in the
    # test harness; the outbox statements are fully parameterised, and the
    # service name never reaches SQL at all.
    class PgConnection
      # A row the publisher claimed, held under a row lock until the batch
      # commits or rolls back.
      Row = Struct.new(:id, :event_type, :source, :subject, :time, :data, :attempts, keyword_init: true) do
        # The envelope this row becomes, with the row's own `id`. The publisher
        # never mints one: a republish of this row is the same event, and a new
        # id would make a consumer's dedupe key miss.
        def to_envelope
          Envelope.new(
            id: id,
            type: event_type,
            source: source,
            subject: subject,
            time: time,
            data: data
          )
        end

        def to_h
          to_envelope.to_h
        end
      end

      def initialize(connection)
        @connection = connection
      end

      # Whether a transaction is open on this connection. The writer refuses to
      # write when this is false, and that refusal is the whole reason the
      # outbox works.
      #
      # Only `PQTRANS_INTRANS` counts. `PQTRANS_IDLE` is no transaction,
      # `PQTRANS_UNKNOWN` is what a connection that has not run a statement yet
      # reports, and `PQTRANS_INERROR` is a failed transaction whose statements
      # are being ignored until it is rolled back — writing into one succeeds at
      # the protocol level and vanishes at the rollback, which is the worst of
      # both answers. An earlier version asked "is it not idle", which made a
      # brand-new connection look like it was inside a transaction and quietly
      # disabled the one check the table depends on.
      def in_transaction?
        @connection.transaction_status == PG::PQTRANS_INTRANS
      end

      def insert(envelope)
        @connection.exec_params(INSERT_SQL, [
                                  envelope.id,
                                  envelope.type,
                                  envelope.source,
                                  envelope.subject,
                                  envelope.time.utc.iso8601,
                                  JSON.generate(envelope.data)
                                ])
        nil
      end

      # The publisher's only query. `for update skip locked` is what lets N
      # replicas run this loop against one table: a row another publisher is
      # holding is skipped rather than blocked on, so a slow batch in one
      # replica cannot stall the rest.
      #
      # The backoff predicate is core's rule — "attempts grows, the wait grows
      # with it" — expressed against core's fixed column list. There is no
      # `next_attempt_at` column and this library does not add one: the column
      # list is a contract, and `created_at` is the one instant every row
      # definitely has. An event that sat unpublished for an hour still has the
      # `created_at` it was written with, so the schedule stays correct.
      #
      # `now` is a parameter rather than the database's `now()` so that the
      # publisher's clock is the only clock. A loop that evaluated its own
      # schedule against a different clock than the one it inserts timestamps
      # with is a loop whose backoff is a function of clock skew.
      #
      # The backoff for a row at zero attempts is **zero seconds**: a row that
      # has never been published is due now, and a first attempt held back for a
      # second is a first attempt that was delayed for no reason. After one
      # failure the wait is one second, then two, then four — core's "1s, 2s,
      # 4s, … capped".
      def claim_batch(limit:, max_attempts:, max_backoff:, now:)
        @connection.exec_params(CLAIM_SQL, [ limit, max_attempts, max_backoff, now.utc.iso8601 ]).map do |row|
          Row.new(
            id: row.fetch("id"),
            event_type: row.fetch("event_type"),
            source: row.fetch("source"),
            subject: row.fetch("subject"),
            time: parse_time(row.fetch("time")),
            data: parse_data(row.fetch("data")),
            attempts: row.fetch("attempts").to_i
          )
        end
      end

      # Marked only from the transport's acknowledgement. Never before.
      def mark_published(id)
        @connection.exec_params(MARK_PUBLISHED_SQL, [ id ])
      end

      def mark_failed(id)
        @connection.exec_params(MARK_FAILED_SQL, [ id ])
      end

      # Run the block in a transaction, **joining one that is already open**.
      #
      # `pg`'s own `Connection#transaction` is not nesting-aware: it issues
      # `BEGIN` unconditionally and commits in an `ensure`, so calling it inside a
      # transaction that a caller opened makes PostgreSQL warn that a transaction
      # is already in progress and then commit the caller's work early. For a
      # library whose entire promise is that the caller's transaction decides
      # whether the row survives, committing it from underneath is the one bug
      # this class must not have.
      #
      # So a nested call joins. The outermost `run_once` opens and commits; a
      # nested one enlists, and its marks are rolled back with the caller's
      # transaction if that rolls back — which is the correct answer, because the
      # rows are still claimable.
      def transaction
        return yield if in_transaction?

        @connection.transaction { yield }
      end

      private

      # The insert, in both placeholder conventions the two adapters need:
      # `$1..$6` for `pg`'s `exec_params`, and `?` for Active Record's
      # `sanitize_sql_array`. Two spellings of one statement, adjacent, so the two
      # adapters cannot drift into writing different SQL.
      INSERT_SQL = <<~SQL
        insert into outbox_events (id, event_type, source, subject, time, data)
        values ($1, $2, $3, $4, $5::timestamptz, $6::jsonb)
      SQL

      INSERT_TEMPLATE = <<~SQL
        insert into outbox_events (id, event_type, source, subject, time, data)
        values (?, ?, ?, ?, ?::timestamptz, ?::jsonb)
      SQL

      # No `on conflict do nothing`. A conflict here means a uuid collision or a
      # caller passing an id it does not own, and both are bugs; a silent no-op
      # would turn one into an event that a consumer believes was published.
      #
      # The `case` is the backoff schedule, and it is written out rather than
      # folded into `power()` so that "never attempted is due now" is readable
      # in the statement itself rather than inferred from a `greatest`.
      CLAIM_SQL = <<~SQL
        select id, event_type, source, subject, time, data, attempts
          from outbox_events
         where published_at is null
           and attempts < $2
           and created_at + (case when attempts = 0 then 0
                              else least($3, power(2, attempts - 1)) end * interval '1 second') <= $4::timestamptz
         order by created_at, id
         limit $1
           for update skip locked
      SQL

      MARK_PUBLISHED_SQL = "update outbox_events set published_at = now() where id = $1"
      MARK_FAILED_SQL = "update outbox_events set attempts = attempts + 1 where id = $1"

      def parse_time(value)
        value.is_a?(Time) ? value : Time.parse(value.to_s).utc
      end

      def parse_data(value)
        value.is_a?(Hash) ? value : JSON.parse(value.to_s)
      end
    end
  end
end
