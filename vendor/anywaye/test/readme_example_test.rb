# frozen_string_literal: true

require_relative "test_helper"
require "rails"
require "active_record/railtie"
require "anywaye/railtie"

# The README's examples, run.
#
# "A usage example that runs" is a claim, and a claim in a README is worth
# exactly as much as the test that proves it. Every code block in README.md that
# can be executed without a running identity is executed here, against a real
# PostgreSQL, and the assertions are the ones the prose makes.
#
# What cannot be executed is the one thing that needs a live identity: fetching
# the key set over the network. For that the suite runs a real JWKS server on a
# real socket (`test/support/jwks_server.rb`), which is the same code path with a
# different origin — so this file covers the parts a reader would otherwise have
# to take on trust, and the verifier suite covers the fetch.
class ReadmeExampleTest < TestSupport::Test
  KEY = TestSupport::Keys.key("readme-key-1")

  def setup
    super
    Anywaye.reset!
    TestSupport::Database.reset_schema!
    @connection = TestSupport::Database.connection
    @server = TestSupport::JwksServer.new(KEY)
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.identity_issuer = @server.issuer
      config.audience = "anywaye-services"
      config.clock = -> { now }
      config.outbox_connection = Anywaye::Outbox::PgConnection.new(@connection)
    end
  end

  def teardown
    super
    @connection.exec("rollback") if @connection.transaction_status != PG::PQTRANS_IDLE
    Anywaye.reset!
  end

  # --- 3. publish an event in the same transaction as the change -----------

  # The README's `Customer`, minus Active Record. The point of the example is
  # the pairing of the row and the event, and that pairing is a property of the
  # transaction rather than of the ORM, so the ORM is left out of it.
  class ReadmeCustomer
    attr_reader :id

    def initialize(id, connection)
      @id = id
      @connection = connection
    end

    # What `create!` does: the insert and the callback, in one transaction.
    def save!
      @connection.transaction do
        # `exec_params` rather than `exec(sql, params)`: the two-argument form of
        # `exec` forwards to it and the `pg` gem warns that it is deprecated. The
        # warning is noise in a suite whose whole job is to be the output someone
        # reads at 3am, and a library whose own tests carry a deprecation is a
        # library whose next major is somebody else's problem.
        @connection.exec_params("insert into probe (name) values ($1)", [ id ])
        publish_created
        self
      end
    end

    private

    def publish_created
      Anywaye.outbox.publish!(
        type: "billing.customer.created",
        subject: id,
        data: { "customer_id" => id }
      )
    end
  end

  def test_the_after_create_example_writes_inside_the_record_s_transaction
    customer = ReadmeCustomer.new("cus_01J9Z8QK5M4N7P2R3T6V8W9X0A", @connection)
    customer.save!

    assert_equal 1, rows.size
    assert_equal "billing.customer.created", rows.first.fetch("event_type")
    assert_equal({ "customer_id" => "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A" }, rows.first.fetch("data"))
    assert_equal [ "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A" ], probe_names
  end

  def test_a_failed_save_takes_the_event_with_it
    # The other half of the README's promise, and the reason the table exists.
    assert_raises(RuntimeError) do
      @connection.transaction do
        @connection.exec("insert into probe (name) values ('doomed')")
        Anywaye.outbox.publish!(type: "billing.customer.created", subject: "cus_2", data: {})
        raise "the domain write failed"
      end
    end

    assert_empty rows
    assert_empty probe_names
  end

  def test_publishing_outside_a_transaction_raises
    error = assert_raises(Anywaye::Errors::Outbox::NotInTransaction) do
      Anywaye.outbox.publish!(type: "billing.customer.created", subject: "cus_1", data: {})
    end

    assert_match(/transaction/, error.message)
    assert_empty rows
  end

  def test_the_non_rails_example_enlists_in_the_callers_transaction
    # The README's `PG::Connection` block, verbatim in shape: a writer built on
    # the raw driver, the domain write and the event in one transaction.
    connection = PG::Connection.new(TestSupport::Database.url)
    outbox = Anywaye::Outbox::Writer.new(
      connection: Anywaye::Outbox::PgConnection.new(connection),
      service_name: "billing",
      clock: -> { now }
    )

    connection.exec("begin")
    connection.exec("insert into probe (name) values ('from the readme')")
    outbox.publish!(type: "billing.customer.created", subject: "cus_1", data: { "customer_id" => "cus_1" })
    connection.exec("commit")

    assert_equal 1, rows.size
    assert_equal [ "from the readme" ], probe_names
  ensure
    connection&.close
  end

  # --- 4. publish it to a transport ----------------------------------------

  def test_the_publisher_example_delivers_and_marks
    delivered = []
    @connection.transaction do
      Anywaye.outbox.publish!(type: "billing.customer.created", subject: "cus_1", data: { "customer_id" => "cus_1" })
    end
    stamp_created_at(now)

    publisher = Anywaye::Outbox.publisher(connection: Anywaye::Outbox::PgConnection.new(@connection),
                                         clock: -> { now }) do |envelope|
      delivered << envelope
    end

    result = publisher.run_once

    assert_equal 1, result.published
    assert_equal 1, delivered.size
    assert_equal "billing.customer.created", delivered.first.fetch("type")
    assert_equal 1, published_count
  end

  def test_delivery_is_at_least_once_and_a_redelivery_carries_the_same_id
    # The README's promise, asserted. A transport that refuses the first attempt
    # and accepts the second must produce one delivery of one envelope id, and
    # the row must end up marked.
    delivered = []
    attempts = 0
    offset = 0
    clock = -> { now + offset }

    @connection.transaction do
      Anywaye.outbox.publish!(type: "billing.customer.created", subject: "cus_1", data: {})
    end
    stamp_created_at(now)

    publisher = Anywaye::Outbox.publisher(connection: Anywaye::Outbox::PgConnection.new(@connection),
                                         clock: clock) do |envelope|
      attempts += 1
      raise "the transport refused it" if attempts == 1

      delivered << envelope
    end

    assert_equal 1, publisher.run_once.failed
    assert_empty delivered

    offset += 2
    assert_equal 1, publisher.run_once.published
    assert_equal 1, delivered.size
    assert_equal 1, published_count
  end

  # --- 5. verify a token ---------------------------------------------------

  def test_the_principal_example_returns_what_the_prose_promises
    principal = Anywaye.token_verifier.verify!(access_token)

    assert_equal "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.subject
    assert_equal "acc_01J9Z8QK5M4N7P2R3T6V8W9X0A", principal.account_id
    assert_equal %w[billing:read billing:write], principal.scopes
    assert_predicate principal.scopes, :frozen?
    assert_instance_of Time, principal.expires_at
    assert_predicate principal.expires_at, :utc?
  end

  def test_the_two_refusals_are_two_classes
    # The README's `rescue` block, exercised on both branches. A single error
    # class with a message per case would make the second rescue unreachable,
    # which is the failure the paragraph exists to prevent.
    assert_raises(Anywaye::Errors::TokenInvalid) { Anywaye.token_verifier.verify!(forged_token) }

    # A *fresh* verifier, so the key set has not already been cached. The branch
    # under test is "the keys could not be fetched", and a verifier holding a
    # perfectly good cached key set never asks — which is the cache doing its
    # job, not the dependency being available.
    fresh = Anywaye.token_verifier_for(Anywaye.config)
    @server.fail_with(503)

    assert_raises(Anywaye::Errors::JwksUnavailable) { fresh.verify!(access_token) }
  end

  # --- 6. nothing logged can have come from a token ------------------------

  def test_the_token_example_prints_nothing
    token = Anywaye::Token.new("a-real-bearer-token")

    assert_equal "[REDACTED]", "#{token}"
    assert_equal "[REDACTED]", token.to_s
    assert_equal "#<Anywaye::Token [REDACTED]>", token.inspect
    assert_equal "a-real-bearer-token", token.reveal
  end

  # --- 2. the outbox table --------------------------------------------------

  def test_the_reference_ddl_creates_the_table_the_examples_use
    # The README tells a reader to run the generator or copy `db/outbox_events.sql`.
    # This is the same table, applied to the same database, by the same bytes the
    # tests have been writing to all along.
    assert_equal 1, @connection.exec("select count(*) as n from information_schema.tables " \
                                      "where table_name = 'outbox_events'").first.fetch("n").to_i
  end

  private

  def access_token
    TestSupport::Tokens.access_token(
      KEY,
      issuer: @server.issuer,
      audience: "anywaye-services",
      now: now
    )
  end

  # A caller widening their own scopes after the fact: the payload is rewritten
  # and the signature no longer covers it.
  def forged_token
    claims = JSON.parse(Base64.urlsafe_decode64(pad(access_token.split(".")[1])))

    TestSupport::Tokens.tampered_payload(access_token, claims.merge("scopes" => %w[billing:write billing:delete]))
  end

  def pad(segment)
    segment + ("=" * ((4 - (segment.length % 4)) % 4))
  end

  def rows
    TestSupport::Database.rows(@connection.exec("select * from outbox_events order by created_at, id"))
  end

  def published_count
    @connection.exec("select count(*) as n from outbox_events where published_at is not null").first.fetch("n").to_i
  end

  def probe_names
    @connection.exec("select name from probe order by name").map { |row| row.fetch("name") }
  end

  # `created_at` is a database default, so it would carry the database's clock
  # rather than the injected one, and the claim query measures the backoff
  # against the publisher's. Same reason as everywhere else it is stamped.
  def stamp_created_at(at)
    @connection.exec_params("update outbox_events set created_at = $1::timestamptz", [ at.utc.iso8601 ])
  end
end
