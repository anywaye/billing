require "test_helper"

class Subscriptions::StateMachineTest < ActiveSupport::TestCase
  LEGAL_TRANSITIONS = {
    nil => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "trialing" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "active" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "past_due" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "unpaid" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "canceled" => { "active" => false, "trialing" => false, "past_due" => false, "unpaid" => false, "canceled" => false }
  }.freeze

  UNMODELLED_STATUSES = %w[incomplete incomplete_expired paused].freeze

  FROMS = ([ nil ] + Subscription::STATUSES).freeze

  test "the machine's table covers every status this service stores, and one for nothing existing" do
    assert_equal FROMS.sort_by(&:to_s), LEGAL_TRANSITIONS.keys.sort_by(&:to_s)
  end

  test "the machine's table names every status as a target" do
    LEGAL_TRANSITIONS.each_value do |targets|
      assert_equal Subscription::STATUSES.sort, targets.keys.sort
    end
  end

  FROMS.each do |from|
    Subscription::STATUSES.each do |to|
      expected = LEGAL_TRANSITIONS.fetch(from).fetch(to)

      test "#{from || 'no subscription'} may #{expected ? '' : 'not '}become #{to}" do
        machine = Subscriptions::StateMachine.new(from, to)

        assert_equal expected, machine.legal?
        assert_equal expected, Subscriptions::StateMachine.new(from, to).legal?
      end
    end
  end

  test "a refusal always carries a reason" do
    FROMS.product(Subscription::STATUSES).each do |from, to|
      machine = Subscriptions::StateMachine.new(from, to)

      if machine.legal?
        assert_nil machine.reason
      else
        assert_predicate machine.reason, :present?, "#{from.inspect} -> #{to} was refused with no reason"
      end
    end
  end

  test "every refusal says the same thing, because there is only one rule" do
    reasons = FROMS.product(Subscription::STATUSES).reject { |from, to| Subscriptions::StateMachine.new(from, to).legal? }
      .map { |from, to| Subscriptions::StateMachine.new(from, to).reason }

    assert_equal [ "canceled_is_terminal" ], reasons.uniq
  end

  test "a subscription may be born canceled, so that a deletion is never dropped" do
    machine = Subscriptions::StateMachine.new(nil, "canceled")

    assert_predicate machine, :legal?
    assert_predicate machine, :creates?
    assert_not machine.live?
  end

  test "a subscription may be born in arrears, because the processor says so" do
    assert_predicate Subscriptions::StateMachine.new(nil, "past_due"), :legal?
    assert_predicate Subscriptions::StateMachine.new(nil, "unpaid"), :legal?
  end

  test "nothing revives a canceled subscription" do
    Subscription::STATUSES.each do |to|
      machine = Subscriptions::StateMachine.new("canceled", to)

      assert_not machine.legal?
      assert_equal "canceled_is_terminal", machine.reason
    end
  end

  test "a canceled subscription stays canceled when the processor repeats the cancellation" do
    machine = Subscriptions::StateMachine.new("canceled", "canceled")

    assert_not machine.legal?
    assert_equal "canceled_is_terminal", machine.reason
  end

  UNMODELLED_STATUSES.each do |status|
    test "#{status} is not a status this service models" do
      assert_not_includes Subscription::STATUSES, status
    end

    test "the machine refuses #{status} rather than guessing what it meant" do
      assert_raises(ArgumentError) { Subscriptions::StateMachine.new("active", status) }
    end
  end

  test "the machine refuses a from-status it does not know" do
    assert_raises(ArgumentError) { Subscriptions::StateMachine.new("incomplete", "active") }
  end

  test "only a start creates a row" do
    assert_predicate Subscriptions::StateMachine.new(nil, "active"), :creates?
    assert_predicate Subscriptions::StateMachine.new(nil, "canceled"), :creates?
    refute_predicate Subscriptions::StateMachine.new("active", "active"), :creates?
    refute_predicate Subscriptions::StateMachine.new("active", "canceled"), :creates?
  end

  test "canceled is the only terminal state, and the machine agrees with the model" do
    assert_equal %w[canceled], Subscription::TERMINAL_STATUSES
    refute_predicate Subscriptions::StateMachine.new("active", "canceled"), :terminal?
    assert_predicate Subscriptions::StateMachine.new("canceled", "canceled"), :terminal?
  end

  test "the machine agrees with the model about which statuses are live" do
    Subscription::STATUSES.each do |status|
      assert_equal Subscription::LIVE_STATUSES.include?(status), Subscriptions::StateMachine.new(status, status).live?
    end
  end
end
