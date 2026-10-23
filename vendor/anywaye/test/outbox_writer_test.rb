# frozen_string_literal: true

require_relative "test_helper"

# The transactional outbox writer, against a real PostgreSQL.
#
# Not a fake. The whole contract of this file is one sentence — "the insert
# rolls back with the state change" — and a fake that pretends to roll back
# would be testing the fake. An exception really discarding an insert is a
# property of PostgreSQL rather than of this code, so the suite runs against
# PostgreSQL and `bin/prime` creates the database.
class OutboxWriterTest < TestSupport::Test
  TYPE = "billing.customer.created"
  SUBJECT = "cus_01J9Z8QK5M4N7P2R3T6V8W9X0A"

  def setup
    super
    TestSupport::Database.reset_schema!
    @connection = TestSupport::Database.connection
    @writer = build_writer
  end

  def teardown
    super
    @connection.exec("rollback") if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  # --- the happy path ------------------------------------------------------

  def test_it_writes_one_row_carrying_the_envelopes_id
    envelope = in_transaction { publish! }

    row = row_for(envelope.id)

    assert_equal("billing.customer.created", row.fetch("event_type"))
    assert_equal("billing", row.fetch("source"))
    assert_equal(envelope.subject, row.fetch("subject"))
    assert_equal(envelope.time, row.fetch("time"))
  end

  def test_the_rows_data_is_the_envelopes_data
    envelope = in_transaction { publish!(data: { "customer_id" => "cus_1" }) }

    assert_equal({ "customer_id" => "cus_1" }, row_for(envelope.id).fetch("data"))
  end

  def test_a_written_row_starts_unpublished_and_unattempted
    # `published_at` is null until the transport acknowledges, and `attempts` is
    # zero. A row that claimed to be published before anything was published is
    # how an event goes missing with a row that says it is fine.
    envelope = in_transaction { publish! }
    row = row_for(envelope.id)

    assert_nil(row.fetch("published_at"))
    assert_equal(0, row.fetch("attempts"))
  end

  def test_the_time_is_when_the_state_changed_not_when_the_row_was_written
    changed_at = now - 86_400

    envelope = in_transaction { publish!(time: changed_at) }

    assert_equal(changed_at, row_for(envelope.id).fetch("time"))
  end

  def test_it_returns_the_envelope_it_wrote
    envelope = in_transaction { publish! }

    assert_equal(envelope.id, row_for(envelope.id).fetch("id"))
    assert_kind_of(Anywaye::Outbox::Envelope, envelope)
  end

  def test_the_source_is_the_service_name_it_was_built_with
    writer = build_writer(service_name: "courier")
    envelope = in_transaction(writer) { publish!(writer, type: "courier.email.queued", data: {}) }

    assert_equal("courier", row_for(envelope.id).fetch("source"))
  end

  # --- the transaction, which is the entire reason for the table ------------

  def test_it_refuses_to_write_outside_a_transaction
    # The failure the whole table exists to make impossible. An event written
    # outside the transaction that wrote the state it describes is exactly the
    # bug, and it is better refused loudly than permitted quietly.
    error = assert_raises(Anywaye::Errors::Outbox::NotInTransaction) { publish! }

    assert_match(/transaction/, error.message)
    assert_empty rows, "a refused write still wrote a row"
  end

  def test_it_never_opens_or_commits_a_transaction_of_its_own
    # The mechanism behind the whole design, asserted directly. If `publish!`
    # issued its own BEGIN and COMMIT it would be a second source of truth, and
    # the rollback test below would pass for the wrong reason.
    @connection.exec("begin")
    publish!
    status = @connection.transaction_status

    assert_equal(PG::PQTRANS_INTRANS, status, "publish! changed the transaction state")
    @connection.exec("rollback")
  end

  def test_a_domain_row_and_its_event_both_survive_a_commit
    in_transaction do
      @connection.exec("insert into probe (name) values ('kept')")
      publish!
    end

    assert_equal([ "kept" ], probe_names)
    assert_equal(1, rows.size)
  end

  def test_a_raise_mid_transaction_rolls_the_event_back
    # The test the packet asks for. The domain row and the event go together:
    # the `assert_raises` is around the whole block, not around the publish,
    # because the failure is the *caller's* and the event's fate is the
    # collateral.
    assert_raises(RuntimeError) do
      @connection.transaction do
        @connection.exec("insert into probe (name) values ('rolled back')")
        publish!
        raise "the domain write failed after the event was queued"
      end
    end

    assert_empty probe_names, "the domain row survived its own rollback"
    assert_empty rows, "an event was emitted for a state change that did not happen"
  end

  def test_the_same_holds_when_the_domain_write_itself_fails
    assert_raises(PG::UniqueViolation) do
      @connection.transaction do
        @connection.exec("insert into probe (name) values ('dupe')")
        @connection.exec("insert into probe (name) values ('dupe')")
        publish!
      end
    end

    assert_empty rows
  end

  def test_the_publisher_loop_never_runs_from_inside_the_request
    # Stated as a property of this API rather than of any caller's discipline:
    # the writer has no `deliver`, no `flush` and no `enqueue`, so there is
    # nothing on this object to reach for. Publishing after commit from an
    # in-memory queue is the same bug with a nicer syntax, and an API without
    # the method cannot be used that way by accident.
    refute_respond_to(@writer, :deliver)
    refute_respond_to(@writer, :flush)
    refute_respond_to(@writer, :enqueue)
    refute_includes(Anywaye::Outbox::Writer.instance_methods(false), :transaction)
  end

  # --- the id --------------------------------------------------------------

  def test_every_emission_mints_a_fresh_id
    ids = 5.times.map { in_transaction { publish! }.id }

    assert_equal(5, ids.uniq.size)
  end

  def test_a_retry_of_the_same_logical_event_mints_a_new_id
    # A caller that rescues a failed transaction and runs the block again is
    # re-emitting the same logical event, and core is explicit: the id is never
    # reused, including on a re-emission. Reusing it would make a consumer's
    # dedupe key drop the second attempt as a duplicate of the first, which is
    # exactly the failure dedupe exists to prevent.
    first = nil
    assert_raises(RuntimeError) do
      @connection.transaction do
        first = publish!
        raise "rolled back"
      end
    end
    second = in_transaction { publish! }

    refute_equal(first.id, second.id)
  end

  def test_a_duplicated_id_is_a_loud_failure_and_not_a_silent_no_op
    # `on conflict do nothing` would hide a uuid collision, or a caller passing
    # an id it does not own. Both are bugs, and a bug that is silent is a bug
    # that is found by a consumer.
    first = in_transaction { publish! }

    assert_raises(PG::UniqueViolation) do
      in_transaction { publish!(id: first.id) }
    end
  end

  # --- the payload ---------------------------------------------------------

  def test_it_refuses_a_payload_its_registered_validator_rejects
    # core's outbox checklist asks for `data` to be validated against
    # `schemas/events/<type>.schema.json` before the insert. A service that has
    # registered a validator gets it run; see the DECISION NEEDED in anywaye.yml
    # for why this gem takes a callable rather than carrying a JSON Schema
    # validator of its own.
    writer = build_writer(payload_validators: {
                            TYPE => ->(data) { raise ArgumentError, "email is required" unless data.key?("email") }
                          })

    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) do
      in_transaction(writer) { publish!(writer, data: { "customer_id" => "cus_1" }) }
    end

    assert_empty rows
  end

  def test_a_rejected_payload_is_caught_before_the_insert_and_not_by_rolling_one_back
    # The assertion is about ordering. "No row exists" cannot tell a validator
    # that refused before the write from one that ran afterwards and left
    # something for the rollback to clean up, so the counter is what actually
    # proves the validate-then-insert order.
    writer = build_writer(payload_validators: { TYPE => ->(_data) { raise ArgumentError, "no" } })

    assert_raises(Anywaye::Errors::Outbox::EnvelopeInvalid) do
      in_transaction(writer) { publish!(writer) }
    end

    assert_equal(0, writer.events_written)
    assert_empty rows
  end

  def test_a_type_with_no_registered_validator_is_written_unvalidated
    # Refusing to write a type this library has no validator for would make
    # every service ship a validator before it could emit its first event, and
    # core ships two payload schemas in total.
    in_transaction { publish!(type: "billing.plan.updated", data: { "anything" => true }) }

    assert_equal(1, rows.size)
  end

  def test_it_counts_the_events_it_wrote
    in_transaction { publish! }
    in_transaction { publish! }

    assert_equal(2, @writer.events_written)
  end

  # --- the service name ----------------------------------------------------

  def test_it_refuses_a_service_name_that_is_not_a_service_name
    assert_raises(Anywaye::Errors::ConfigurationError) { build_writer(service_name: "Billing") }
  end

  def test_it_refuses_an_empty_service_name
    assert_raises(Anywaye::Errors::ConfigurationError) { build_writer(service_name: "") }
  end

  private

  def build_writer(**overrides)
    Anywaye::Outbox::Writer.new(
      **{
        connection: Anywaye::Outbox::PgConnection.new(@connection),
        service_name: "billing",
        clock: -> { now },
        id_generator: -> { SecureRandom.uuid }
      }.merge(overrides)
    )
  end

  def publish!(writer = @writer, **overrides)
    writer.publish!(**{ type: TYPE, subject: SUBJECT, data: { "customer_id" => "cus_1" } }.merge(overrides))
  end

  def in_transaction(writer = @writer)
    @connection.transaction do
      yield
    end
  end

  def rows
    TestSupport::Database.rows(@connection.exec("select * from outbox_events order by created_at, id"))
  end

  def row_for(id)
    TestSupport::Database.row(@connection.exec_params("select * from outbox_events where id = $1", [ id ]))
  end

  def probe_names
    @connection.exec("select name from probe order by name").map { |row| row.fetch("name") }
  end
end
