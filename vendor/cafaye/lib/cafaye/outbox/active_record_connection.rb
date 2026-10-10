# frozen_string_literal: true

require "json"

module Cafaye
  module Outbox
    # The outbox table, over an Active Record connection.
    #
    # The same statements as `PgConnection`, issued through Active Record's
    # adapter instead of the `pg` driver directly. It exists because of the one
    # requirement the outbox has and that a second connection could never meet:
    # **the insert has to be on the connection that is inside the caller's
    # transaction.** A `Pg::Connection` opened from the same database config is
    # a different session, is not enlisted, and would commit the event on its own
    # — which is the exact failure the table exists to prevent, wearing the
    # costume of a correct implementation.
    #
    # So this adapter takes the connection *pool* and asks it for the connection
    # Active Record is currently leasing, rather than opening one.
    class ActiveRecordConnection
      def initialize(pool)
        @pool = pool
      end

      # Builds one from an Active Record base class or model, which is what a
      # host application has.
      def self.for(base)
        new(base.connection_handler.retrieve_connection_pool(base) || base.connection_pool)
      end

      def in_transaction?
        connection.open_transactions.positive?
      end

      def insert(envelope)
        # Quoted by Active Record rather than by hand, and rather than through
        # `QueryAttribute` and a type object per column: `sanitize_sql_array` is
        # the supported path, it quotes and casts every value through the adapter,
        # and it does not need this library to know that PostgreSQL spells its
        # uuid type `uuid` and Active Record spells its class something else.
        connection.execute(
          ::ActiveRecord::Base.sanitize_sql_array(
            [ PgConnection::INSERT_TEMPLATE,
              envelope.id, envelope.type, envelope.source, envelope.subject,
              envelope.time.utc.iso8601, JSON.generate(envelope.data) ]
          )
        )
        nil
      end

      def claim_batch(limit:, max_attempts:, max_backoff:, now:)
        # The same statement as `PgConnection`'s, with the four values
        # interpolated. `run_once` refuses a `limit`, `max_attempts` or
        # `max_backoff` that is not a positive Integer before this is reached,
        # and `now` comes from the publisher's own clock, so there is no path by
        # which an operator-supplied string lands in the SQL. Interpolating is
        # what lets both adapters share one statement, which is the point: two
        # copies of the publisher's only query is two answers to a question a
        # consumer asks once.
        connection.select_all(
          PgConnection::CLAIM_SQL
            .gsub("$1", Integer(limit).to_s)
            .gsub("$2", Integer(max_attempts).to_s)
            .gsub("$3", Integer(max_backoff).to_s)
            .gsub("$4", connection.quote(now.utc.iso8601)),
          "Cafaye Outbox Claim"
        ).map { |row| ActiveRecordConnection.row_from(row) }
      end

      # `exec_update`'s third argument is a flat list of bind values. The extra
      # leading type caster belongs to `exec_insert`, whose first column is an
      # auto-generated primary key; passing one here tells Active Record the
      # statement has two placeholders, and PostgreSQL answers `could not
      # determine data type of parameter $2`.
      def mark_published(id)
        connection.exec_update(ActiveRecordConnection::MARK_PUBLISHED_SQL, "Cafaye Outbox Mark", [ id ])
      end

      def mark_failed(id)
        connection.exec_update(ActiveRecordConnection::MARK_FAILED_SQL, "Cafaye Outbox Mark", [ id ])
      end

      # Active Record *is* nesting-aware: a `transaction` inside another joins the
      # outer one and only the outermost commits. So this delegates, and the
      # `PgConnection` equivalent's own guard is not needed here.
      def transaction(&block)
        connection.transaction(&block)
      end

      # The leased connection, taken fresh each time. Holding it in an ivar
      # would be wrong: Active Record leases per thread, and a publisher thread
      # that cached a connection from the request thread would write on the
      # wrong session.
      def connection
        @pool.lease_connection
      end

      class << self
        def row_from(row)
          PgConnection::Row.new(
            id: row.fetch("id"),
            event_type: row.fetch("event_type"),
            source: row.fetch("source"),
            subject: row.fetch("subject"),
            time: parse_time(row.fetch("time")),
            data: parse_data(row.fetch("data")),
            attempts: row.fetch("attempts").to_i
          )
        end

        private

        def parse_time(value)
          value.is_a?(Time) ? value : Time.parse(value.to_s).utc
        end

        def parse_data(value)
          value.is_a?(Hash) ? value : JSON.parse(value.to_s)
        end
      end

      # The statements both adapters share, in `pg`'s placeholder convention.
      # `claim_batch` interpolates its own four; these two bind directly.
      MARK_PUBLISHED_SQL = PgConnection::MARK_PUBLISHED_SQL
      MARK_FAILED_SQL = PgConnection::MARK_FAILED_SQL
    end
  end
end
