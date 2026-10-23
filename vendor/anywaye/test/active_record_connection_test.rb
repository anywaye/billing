# frozen_string_literal: true

require_relative "test_helper"
require "active_record"
require "anywaye/outbox/active_record_connection"

# The Active Record adapter, against a real Active Record connection to a real
# PostgreSQL.
#
# The whole reason this adapter exists is the one property a second `PG::Connection`
# could never have: **the insert has to be on the connection that is inside the
# caller's transaction.** Two connections, one database, and the event commits on
# its own while the domain row rolls back — which is the exact failure the outbox
# exists to prevent, wearing the costume of a correct implementation. So these
# tests are about enlistment, and the rollback one is the load-bearing test in the
# whole file.
class ActiveRecordConnectionTest < TestSupport::Test
  def setup
    super
    TestSupport::Database.reset_schema!
    ActiveRecord::Base.establish_connection(TestSupport::Database.url)
    @connection = Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base)
    @writer = Anywaye::Outbox::Writer.new(
      connection: @connection,
      service_name: "billing",
      clock: -> { now }
    )
  end

  def teardown
    super
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  # --- enlistment ----------------------------------------------------------

  def test_it_writes_a_row_inside_an_active_record_transaction
    envelope = nil

    ActiveRecord::Base.transaction do
      envelope = @writer.publish!(type: TYPE, subject: SUBJECT, data: { "customer_id" => "cus_1" })
    end

    assert_equal "billing.customer.created", row_for(envelope.id).fetch("event_type")
  end

  def test_a_rollback_takes_the_event_with_the_domain_write
    # The test that justifies the adapter existing. A `PG::Connection` built from
    # the same config would commit this event while the subscription rolled back,
    # and the event would be on the bus describing a row that does not exist.
    assert_raises(RuntimeError) do
      ActiveRecord::Base.transaction do
        @writer.publish!(type: TYPE, subject: SUBJECT, data: { "customer_id" => "cus_1" })
        raise "the domain write failed after the event was queued"
      end
    end

    assert_empty rows, "an event was committed outside the caller's transaction"
  end

  def test_it_reports_an_open_transaction
    refute_predicate(@connection, :in_transaction?)

    ActiveRecord::Base.transaction do
      assert_predicate(@connection, :in_transaction?)
    end

    refute_predicate(@connection, :in_transaction?)
  end

  def test_it_refuses_to_write_outside_a_transaction
    assert_raises(Anywaye::Errors::Outbox::NotInTransaction) do
      @writer.publish!(type: TYPE, subject: SUBJECT, data: {})
    end
  end

  # --- the same statements, on this adapter --------------------------------

  def test_it_stores_the_payload_as_parsed_jsonb
    envelope = ActiveRecord::Base.transaction do
      @writer.publish!(type: TYPE, subject: SUBJECT, data: { "customer_id" => "cus_1", "amount_minor" => 1900 })
    end

    assert_equal({ "customer_id" => "cus_1", "amount_minor" => 1900 }, row_for(envelope.id).fetch("data"))
  end

  def test_the_claim_mark_and_rollback_verbs_work
    seed
    delivered = []

    result = @connection.transaction do
      claimed = @connection.claim_batch(limit: 10, max_attempts: 10, max_backoff: 300, now: now)
      claimed.each do |row|
        delivered << row.to_h
        @connection.mark_published(row.id)
      end
      claimed.size
    end

    assert_equal 1, result
    assert_equal 1, delivered.size
    assert_equal SUBJECT, delivered.first.fetch("subject")
    assert_equal 1, published_count
  end

  def test_the_publisher_runs_on_this_adapter_and_marks_nothing_when_a_delivery_fails
    seed

    publisher = Anywaye::Outbox::Publisher.new(
      connection: @connection,
      clock: -> { now },
      deliverer: ->(_envelope) { raise "the transport is down" },
      logger: nil
    )

    result = publisher.run_once

    assert_equal 1, result.failed
    assert_equal 0, published_count
    assert_equal 1, attempts_of(first_id)
  end

  def test_a_row_past_the_attempt_cap_is_not_claimed
    seed
    ActiveRecord::Base.connection.execute("update outbox_events set attempts = 9")

    publisher = Anywaye::Outbox::Publisher.new(
      connection: @connection, clock: -> { now }, deliverer: ->(_e) { }, logger: nil
    )

    assert_equal 0, publisher.run_once(max_attempts: 5).claimed
  end

  # --- construction --------------------------------------------------------

  def test_it_can_be_built_from_a_model_rather_than_a_base_class
    # A host application has `ApplicationRecord` or a model, and asking for the
    # pool from either must work.
    seed
    connection = Anywaye::Outbox::ActiveRecordConnection.for(ActiveRecord::Base)

    assert_kind_of PG::Connection, connection.connection.raw_connection
  end

  def test_the_leased_connection_is_the_one_active_record_is_using
    # Holding a connection in an ivar would be wrong: Active Record leases per
    # thread, and a publisher thread that cached a connection from the request
    # thread would write on the wrong session.
    assert_same ActiveRecord::Base.connection_pool.lease_connection, @connection.connection
  end

  private

  TYPE = "billing.customer.created"
  SUBJECT = "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A"

  # One event, written in a transaction and then stamped with the injected
  # clock's `created_at`.
  #
  # The stamp is not tidiness. `created_at` is a database default and so carries
  # the *database's* clock, while the claim query measures the backoff against
  # the publisher's — so without the stamp a row written "now" is not yet due
  # for its first attempt as far as the injected clock is concerned, and a test
  # about claiming claims nothing.
  def seed
    ActiveRecord::Base.transaction do
      @writer.publish!(type: TYPE, subject: SUBJECT, data: { "customer_id" => "cus_1" })
    end
    ActiveRecord::Base.connection.execute(
      "update outbox_events set created_at = #{quote(now.utc.iso8601)}::timestamptz"
    )
  end

  def rows
    TestSupport::Database.rows(
      ActiveRecord::Base.connection.select_all("select * from outbox_events order by created_at, id").to_a
    )
  end

  def row_for(id)
    TestSupport::Database.rows(
      ActiveRecord::Base.connection.select_all("select * from outbox_events where id = #{quote(id)}").to_a
    ).first
  end

  def first_id
    rows.first.fetch("id")
  end

  def attempts_of(id)
    ActiveRecord::Base.connection.select_value("select attempts from outbox_events where id = #{quote(id)}").to_i
  end

  def published_count
    ActiveRecord::Base.connection.select_value(
      "select count(*) from outbox_events where published_at is not null"
    ).to_i
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
