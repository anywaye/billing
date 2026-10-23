# frozen_string_literal: true

require_relative "test_helper"

# The publisher loop: the thing that moves committed rows to a transport.
#
# Two claims are load-bearing, and both are tested here against a real
# PostgreSQL with two live connections, because neither is a property of this
# code:
#
# - **`for update skip locked`** is what lets N replicas run this loop against
#   one table. A row another publisher is holding is skipped, not blocked on, so
#   a slow batch in one replica cannot stall the rest.
# - **Ack, then mark.** `published_at` is set from the transport's
#   acknowledgement, never before. A publish that was never acknowledged is an
#   unpublished row and the next pass republishes it — same `id`, so a consumer
#   that already got it ignores the duplicate.
class OutboxPublisherTest < TestSupport::Test
  TYPE = "billing.customer.created"

  def setup
    super
    TestSupport::Database.reset_schema!
    @connection = TestSupport::Database.connection
    @second = PG::Connection.new(TestSupport::Database.url)
    @delivered = []
    @clock_offset = 0
    @deliverer = ->(envelope) { @delivered << envelope }
  end

  def teardown
    super
    @connection.exec("rollback") if @connection.transaction_status != PG::PQTRANS_IDLE
    @second.close unless @second.finished?
  end

  # --- claiming ------------------------------------------------------------

  def test_it_delivers_the_rows_that_have_not_been_published
    seed(2)

    result = publisher.run_once

    assert_equal(2, result.claimed)
    assert_equal(2, result.published)
    assert_equal(0, result.failed)
    assert_equal(2, @delivered.size)
  end

  def test_it_delivers_in_created_at_order
    # A slow batch must not publish event 2 before event 1. `created_at` is the
    # ordering key with `id` as the tiebreaker, so two rows written in the same
    # instant still have one order rather than a random one.
    seed(3)

    publisher.run_once

    subjects = @delivered.map { |envelope| envelope.fetch("subject") }

    assert_equal(%w[cus_0 cus_1 cus_2], subjects)
  end

  def test_a_batch_may_be_smaller_than_the_table
    seed(5)

    result = publisher.run_once(batch_size: 2)

    assert_equal(2, result.claimed)
    assert_equal(2, @delivered.size)
    assert_equal(2, published_count)
  end

  def test_it_ignores_rows_that_are_already_published
    seed(3)
    mark_published(first_id)

    assert_equal(2, publisher.run_once.claimed)
    # Three, not two: the row marked above was published by an earlier pass and
    # stays marked, and the two this pass delivered join it. The claim is the
    # assertion that matters — a publisher that re-claimed a published row would
    # deliver it twice with the same id, which is safe for a consumer and pure
    # waste for everyone.
    assert_equal(3, published_count)
  end

  def test_a_second_publisher_skips_the_rows_the_first_is_holding
    # Two replicas, one table. The second session claims inside its own open
    # transaction and must neither block on the first's rows nor receive them.
    seed(4)
    first_ids = nil

    @connection.transaction do
      first_ids = publisher.run_once(batch_size: 2).ids
      assert_equal(2, first_ids.size)
    end

    @second.transaction do
      second_ids = publisher_for(@second, @delivered).run_once(batch_size: 2).ids

      assert_equal(2, second_ids.size)
      assert_empty(second_ids & first_ids, "two publishers delivered the same row")
    end
  end

  def test_a_second_publisher_makes_progress_while_the_first_still_holds_rows
    # The narrower and more useful form: the second replica must be able to
    # deliver the rows the first is *not* holding rather than stalling behind
    # the one it is.
    seed(3)

    @connection.transaction do
      held = publisher.run_once(batch_size: 1).ids
      assert_equal(1, held.size)

      @second.transaction do
        second_ids = publisher_for(@second, @delivered).run_once(batch_size: 5).ids

        assert_equal(2, second_ids.size)
        refute_includes(second_ids, held.first)
      end
    end
  end

  # --- acknowledging -------------------------------------------------------

  def test_a_row_is_marked_published_only_after_the_transport_acknowledges
    # Marking before the acknowledgement is the "handed to a client" bug, and a
    # process that dies in exactly that window loses the event for good.
    seed(1)
    published_during_delivery = nil
    @deliverer = lambda { |_envelope|
      published_during_delivery = published_count
      @delivered << :ok
    }

    publisher.run_once

    assert_equal(0, published_during_delivery, "the row was marked before the transport acknowledged")
    assert_equal(1, published_count)
  end

  def test_a_failed_delivery_leaves_the_row_unpublished_and_counts_the_attempt
    # Delivery is at-least-once, and that is a contract with consumers rather
    # than a bug to paper over. The row stays, the attempt is recorded, and the
    # next pass tries again with the same `id`.
    seed(1)
    @deliverer = ->(_envelope) { raise "the transport refused the message" }

    result = publisher.run_once

    assert_equal(1, result.failed)
    assert_equal(0, result.published)
    assert_equal(0, published_count)
    assert_equal(1, attempts_of(first_id))
  end

  def test_a_failed_delivery_does_not_stop_the_rest_of_the_batch
    # core: "a consumer that cannot process an event must not block the queue".
    # A single poison event must not wedge the publisher for the service.
    seed(3)
    @deliverer = lambda { |envelope|
      raise "the transport refused this one" if envelope.fetch("subject") == "cus_1"

      @delivered << envelope
    }

    result = publisher.run_once

    assert_equal(2, result.published)
    assert_equal(1, result.failed)
    assert_equal(2, published_count)
  end

  def test_a_batch_where_every_delivery_fails_marks_nothing_and_raises_nothing
    # A transport that is refusing everything is an outage the loop absorbs: the
    # rows stay, the attempts go up, the pass returns, and the next pass backs
    # off. Raising here would take the worker's supervisor down for a condition
    # the retry schedule exists to handle, and would leave the batch uncommitted
    # so the attempt count never grew.
    seed(2)
    @deliverer = ->(_envelope) { raise "the transport refused the message" }

    result = nil
    result = publisher.run_once

    assert_equal(2, result.failed)
    assert_equal(0, published_count)
    assert_equal([ 1, 1 ], rows.map { |row| row.fetch("attempts") }.sort)
  end

  def test_a_pass_that_cannot_even_claim_its_batch_raises_and_marks_nothing
    # The fatal case, and the one a supervisor needs to hear about: a batch that
    # cannot be claimed is an outage, not a poison event. Nothing was marked,
    # because the marks are in the same transaction, so every row is still
    # claimable and the next pass starts from the same place.
    seed(1)
    drop_outbox_table

    assert_raises(Anywaye::Errors::Outbox::DeliveryFailed) { publisher.run_once }

    assert_empty @delivered
  end

  def test_a_republished_row_carries_the_same_id_so_a_consumer_can_dedupe
    # The whole reason the id lives on the row and is never re-minted by the
    # publisher. A republish that invented a new id would be a second event, and
    # a consumer that dedupes on the id would process it twice.
    seed(1, aged: false)
    @deliverer = ->(_envelope) { raise "the transport dropped the connection after the send" }
    publisher.run_once
    assert_equal(1, attempts_of(first_id))

    @delivered = []
    @deliverer = ->(envelope) { @delivered << envelope.fetch("id") }
    travel(2)
    publisher.run_once

    assert_equal([ first_id ], @delivered)
    assert_equal(1, published_count)
  end

  def test_the_delivered_envelope_is_the_row_and_nothing_else
    # Undeclared envelope attributes are rejected by every consumer, so the
    # published hash carries exactly core's seven.
    seed(1)

    publisher.run_once

    assert_equal(1, @delivered.size)
    assert_equal(%w[data id source specversion subject time type], @delivered.first.keys.sort)
    assert_equal("1.0", @delivered.first.fetch("specversion"))
  end

  # --- backoff and the attempt cap -----------------------------------------

  def test_a_failed_row_is_not_reclaimed_until_its_backoff_has_elapsed
    # An event in a hot loop against a broker that is already down is how a
    # dependency outage becomes a database outage.
    seed(1, aged: false)
    @deliverer = ->(_envelope) { raise "down" }
    publisher.run_once

    assert_equal(0, publisher.run_once.claimed, "the second attempt ignored the backoff")
  end

  def test_a_row_is_reclaimed_once_its_backoff_has_elapsed
    seed(1, aged: false)
    @deliverer = ->(_envelope) { raise "down" }
    publisher.run_once
    @deliverer = ->(envelope) { @delivered << envelope }
    travel(3)

    assert_equal(1, publisher.run_once.claimed)
    assert_equal(1, @delivered.size)
  end

  def test_the_backoff_is_exponential_and_capped
    # The schedule is public because a service needs it for its alerting, and
    # public because a schedule nobody can read is a schedule nobody can tune.
    # Zero attempts is due now: a row that has never been published has never
    # been tried.
    loop_with_backoff = publisher_for(@connection, @delivered, max_backoff: 60)

    assert_equal([ 0, 1, 2, 4, 8, 16, 32, 60, 60 ], (0..8).map { |n| loop_with_backoff.backoff_seconds(n) })
  end

  def test_the_schedule_in_ruby_is_the_schedule_in_the_claim_query
    # The arithmetic exists twice — once in Ruby for a service's alerting, once
    # in the statement that decides what to claim — so the two are compared by
    # running the claim query for real at each step of the schedule, rather than
    # assumed to agree.
    seed(1, aged: false)
    @deliverer = ->(_envelope) { raise "down" }

    (0..6).each do |attempts|
      wait = publisher.backoff_seconds(attempts)
      started = now

      set_attempts(attempts)
      stamp_created_at(started)
      # Nothing has elapsed, so a row that has already failed is not due — and a
      # row that has never been tried is.
      assert_equal(attempts.zero?, publisher.run_once.claimed.positive?,
                   "attempts=#{attempts}, with no time elapsed")

      travel(wait)
      set_attempts(attempts)
      stamp_created_at(started)

      assert(publisher.run_once.claimed.positive?, "attempts=#{attempts}, after #{wait}s")
    end
  end

  def test_the_backoff_is_measured_from_created_at_not_from_the_last_attempt
    # core's column list has no "next attempt" column and adding one would be
    # changing a contract, so the schedule hangs off `created_at` — the insert
    # time, which is the one instant the row definitely has.
    seed(1)
    @deliverer = ->(_envelope) { raise "down" }
    publisher.run_once
    backdate_created_at(3_600)
    @deliverer = ->(envelope) { @delivered << envelope }

    assert_equal(1, publisher.run_once.claimed)
  end

  def test_a_row_past_the_attempt_cap_is_left_alone
    # Past the cap an event stuck for an hour is an incident: alert and leave it.
    # Dropping it silently is the alternative, and silent is a mystery.
    seed(1)
    set_attempts(5)
    @deliverer = ->(_envelope) { raise "down" }

    result = publisher.run_once(max_attempts: 5)

    assert_equal(0, result.claimed)
    assert_equal(5, attempts_of(first_id))
    assert_empty @delivered
    assert_equal(0, published_count)
  end

  def test_a_row_just_under_the_cap_is_still_attempted
    seed(1)
    set_attempts(4)
    backdate_created_at(3_600)

    assert_equal(1, publisher.run_once(max_attempts: 5).claimed)
  end

  # --- configuration -------------------------------------------------------

  def test_a_pass_run_inside_a_callers_transaction_joins_it_rather_than_committing_it
    # `pg`'s own `Connection#transaction` issues `BEGIN` unconditionally and
    # commits in an `ensure`, so a publisher that used it directly would commit
    # the caller's transaction early — the one bug a library whose promise is
    # "the caller's transaction decides whether this row survives" cannot have.
    seed(2)

    @connection.transaction do
      publisher.run_once

      # Still open, and still uncommitted: the marks made by the pass are the
      # caller's business, not the loop's.
      assert_equal PG::PQTRANS_INTRANS, @connection.transaction_status
    end

    assert_equal 2, published_count
  end

  def test_a_pass_inside_a_transaction_that_rolls_back_leaves_the_rows_claimable
    seed(1)
    delivered = []
    @deliverer = ->(envelope) { delivered << envelope }

    assert_raises(RuntimeError) do
      @connection.transaction do
        publisher.run_once
        raise "the caller changed its mind"
      end
    end

    assert_equal 1, delivered.size, "the transport was called, which is correct"
    assert_equal 0, published_count, "the mark was committed, which is not"
    assert_equal 1, publisher.run_once.claimed, "the row is still claimable"
  end

  def test_it_refuses_a_batch_size_that_is_not_positive
    assert_raises(Anywaye::Errors::ConfigurationError) { publisher.run_once(batch_size: 0) }
  end

  def test_it_refuses_a_zero_attempt_cap
    assert_raises(Anywaye::Errors::ConfigurationError) { publisher.run_once(max_attempts: 0) }
  end

  def test_it_refuses_a_backoff_ceiling_of_zero
    assert_raises(Anywaye::Errors::ConfigurationError) { publisher.run_once(max_backoff: 0) }
  end

  def test_it_does_nothing_when_there_is_nothing_to_publish
    result = publisher.run_once

    assert_equal(0, result.claimed)
    assert_equal(0, result.published)
    assert_equal(0, result.failed)
    assert_empty @delivered
  end

  def test_it_needs_somewhere_to_deliver_to
    assert_raises(Anywaye::Errors::ConfigurationError) do
      Anywaye::Outbox::Publisher.new(connection: Anywaye::Outbox::PgConnection.new(@connection), clock: -> { now })
    end
  end

  private

  def publisher
    publisher_for(@connection, @delivered, deliverer: @deliverer)
  end

  def publisher_for(connection, _sink, deliverer: @deliverer, **overrides)
    Anywaye::Outbox::Publisher.new(
      **{
        connection: Anywaye::Outbox::PgConnection.new(connection),
        clock: -> { now },
        deliverer: deliverer,
        logger: nil
      }.merge(overrides)
    )
  end

  def seed(count, aged: true)
    writer = Anywaye::Outbox::Writer.new(
      connection: Anywaye::Outbox::PgConnection.new(@connection),
      service_name: "billing",
      clock: -> { now }
    )

    @connection.transaction do
      count.times do |index|
        writer.publish!(type: TYPE, subject: "cus_#{index}", data: { "customer_id" => "cus_#{index}" },
                                time: now + index)
      end
    end

    # `created_at` is a database default, so it would carry the *database's*
    # clock while every other time in this file carries the injected one — and
    # the claim query both orders by it and measures the backoff from it. So the
    # rows are stamped a second apart, oldest first. Stamping them in the
    # *future* would order them correctly and leave every row but the first not
    # yet due for its first attempt, which is a very confusing way to discover
    # that the backoff predicate uses the same column.
    #
    # `aged: false` stamps every row at exactly `now`, which is what the
    # backoff tests need: a row that is already a second old has already served
    # its backoff, so a test about the schedule cannot be passing because of the
    # seed.
    count.times do |index|
      stamp_created_at(aged ? now - (count - index) : now, subject: "cus_#{index}")
    end
  end

  def stamp_created_at(at, subject: nil)
    if subject
      @connection.exec_params(
        "update outbox_events set created_at = $1::timestamptz where subject = $2", [ at.utc.iso8601, subject ]
      )
    else
      @connection.exec_params("update outbox_events set created_at = $1::timestamptz", [ at.utc.iso8601 ])
    end
  end

  def rows
    TestSupport::Database.rows(@connection.exec("select * from outbox_events order by created_at, id"))
  end

  def first_id
    rows.first.fetch("id")
  end

  def attempts_of(id)
    TestSupport::Database.row(@connection.exec_params("select attempts from outbox_events where id = $1", [ id ])).fetch("attempts")
  end

  def published_count
    @connection.exec("select count(*) as count from outbox_events where published_at is not null").first.fetch("count").to_i
  end

  def mark_published(id)
    @connection.exec_params("update outbox_events set published_at = now() where id = $1", [ id ])
  end

  def set_attempts(count)
    @connection.exec_params("update outbox_events set attempts = $1", [ count ])
  end

  def drop_outbox_table
    @connection.exec("drop table outbox_events")
  end

  def backdate_created_at(seconds)
    @connection.exec_params(
      "update outbox_events set created_at = created_at - ($1 || ' seconds')::interval", [ seconds ]
    )
  end

  # Moves the injected clock. Nothing in this suite sleeps; the clock moves
  # because the test says it does, which is what makes the backoff assertions
  # deterministic rather than a race against a real second ticking over.
  def travel(seconds)
    @clock_offset += seconds
  end

  def now
    Time.utc(2026, 9, 30, 4, 19, 0) + @clock_offset
  end
end
