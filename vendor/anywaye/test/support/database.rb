# frozen_string_literal: true

require "pg"
require "uri"
require "json"
require "time"

module TestSupport
  # The suite's PostgreSQL database: created if it is missing, and always the
  # gem's own reference DDL.
  #
  # It is a real database rather than a fake for one specific reason. The
  # contract this gem exists to provide is "the insert rolls back with the state
  # change". A fake that pretends to roll back would be testing the fake, and the
  # two things that make the outbox work — `for update skip locked` really
  # skipping a row another session holds, and an exception really discarding the
  # insert — are both properties of PostgreSQL rather than of this code.
  #
  # `bin/prime` runs `rake db:prepare`, which calls `prepare!`, so a clean
  # checkout primes without a manual step. CI sets ANYWAYE_TEST_DATABASE_URL to
  # point at its own service.
  module Database
    DEFAULT_URL = "postgres://localhost/anywaye_test"
    DDL_PATH = File.expand_path("../../db/outbox_events.sql", __dir__)

    class Unreachable < StandardError; end

    module_function

    # The URL under test. `ANYWAYE_TEST_DATABASE_URL` first, so a CI service or a
    # developer's own instance can be pointed at without editing a file.
    def url
      ENV.fetch("ANYWAYE_TEST_DATABASE_URL", DEFAULT_URL)
    end

    # Creates the database when it does not exist and loads the schema. Safe to
    # run repeatedly: both halves are idempotent, because a prime that failed
    # halfway and then failed again for a different reason is worse than one that
    # repairs itself.
    def prepare!
      create_database!
      reset_schema!
      url
    end

    def create_database!
      name = database_name
      return if database_exists?(name)

      with_maintenance_connection do |connection|
        # `create_database` has no `if not exists` in PostgreSQL 15 and earlier,
        # and a race between two checkouts creating the same database is a race
        # the second one loses to an exception it can recognise. The duplicate
        # database error code is 42P04.
        connection.exec("create database #{connection.quote_ident(name)}")
      rescue PG::Error => error
        raise unless error.result&.error_field(PG::Result::PG_DIAG_SQLSTATE) == "42P04"

        nil
      end
      nil
    end

    # A clean schema for one test: create the tables if they are missing, then
    # truncate.
    #
    # Truncate rather than drop-and-recreate. Recreating per test took the suite
    # from one second to ten, which is ten seconds of a developer waiting to
    # learn whether a change is green — and the next thing to happen after that
    # is someone adding a `sleep` to work around the slowness.
    def reset_schema!
      create_tables!
      connection.exec("truncate outbox_events, probe restart identity")
    end

    # The schema itself. For `bin/prime`, and for a test that has deliberately
    # dropped a table.
    def create_tables!
      connection.exec(File.read(DDL_PATH))
      # A stand-in for the domain tables a service owns, so the rollback tests
      # can write a "domain row" in the same transaction and watch it disappear
      # with the event. It is deliberately the *service's* table, not the gem's:
      # the gem never touches it, and a test that used the gem's own table to
      # prove a transaction rolled back would be proving something much smaller.
      connection.exec(<<~SQL)
        create table if not exists probe (
          id serial primary key,
          name text not null unique
        )
      SQL
    end

    def connection
      @connection ||= begin
        conn = PG::Connection.new(url)
        conn.exec("set client_min_messages to warning")
        conn
      rescue PG::Error => error
        raise Unreachable, "cannot reach the test database at #{url}: #{error.message.strip}"
      end
    end

    # Result rows as Ruby values.
    #
    # The `pg` driver hands back every column as a String unless a type map is
    # installed, and the JSON text decoder in pg 1.6 raises on the arguments its
    # own C code passes it — so the decoding lives here, in one place, rather
    # than in a driver internal that changes between patch releases. `data`
    # becomes a Hash and `time` a UTC Time, which is what `envelope.data` and
    # `envelope.time` already are, so a test can compare a row with an envelope
    # without a re-parse in between.
    def rows(result)
      result.map { |row| decode(row) }
    end

    def row(result)
      result.first && decode(result.first)
    end

    def decode(row)
      row.each_with_object({}) do |(column, value), out|
        out[column] =
          case column
          when "data" then value.is_a?(String) ? JSON.parse(value) : value
          when "time", "created_at", "published_at" then decode_time(value)
          when "attempts" then value.to_i
          else value
          end
      end
    end

    def decode_time(value)
      return nil if value.nil?
      return value.utc if value.is_a?(Time)

      Time.parse(value.to_s).utc
    end

    def with_connection
      yield connection
    end

    # Runs the block inside a transaction that is always rolled back, so a test
    # that writes rows does not have to clean up and two tests cannot see each
    # other's rows.
    #
    # A test that asserts a rollback raises inside the block, and the raise
    # propagates out through here: the inner transaction is already gone, and
    # this one discards everything above it too. That is the real shape of the
    # case, so the test does not have to simulate it.
    def in_transaction
      connection.exec("begin")
      yield connection
      connection.exec("rollback")
    rescue StandardError, Minitest::Assertion
      connection.exec("rollback") if idle?
      raise
    end

    private_class_method def idle?
      connection.transaction_status == PG::PQTRANS_IDLE
    end

    private_class_method def with_maintenance_connection
      yield PG::Connection.new(maintenance_url)
    end

    # The database named in the URL, with a quote for the DSN. `postgres` is
    # always present on a working server and is the documented way to ask for
    # "the maintenance database".
    private_class_method def database_name
      url.split("/").last.to_s.split("?").first.to_s
    end

    private_class_method def maintenance_url
      uri = URI.parse(url)
      uri.path = "/postgres"
      uri.to_s
    end

    private_class_method def database_exists?(name)
      with_maintenance_connection do |connection|
        connection.exec_params("select 1 from pg_database where datname = $1", [ name ]).ntuples.positive?
      end
    end
  end
end
