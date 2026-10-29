module ConstraintRefusals
  def assert_refused_by_constraint(message = nil, expected: ActiveRecord::RecordNotUnique)
    violation = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      violation = begin
        yield
        nil
      rescue ActiveRecord::StatementInvalid => e
        e
      end
      raise ActiveRecord::Rollback
    end

    assert_instance_of expected, violation,
      message || "expected the database to refuse the write, got #{violation.inspect}"
  end
end

module ActiveSupport
  class TestCase
    include ConstraintRefusals
  end
end
