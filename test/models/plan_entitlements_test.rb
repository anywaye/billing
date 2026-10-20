require "test_helper"

# A plan's entitlements: what buying it grants.
#
# The column is new in billing-04 and it is a *public* field — it comes back on
# every plan and on `GET /v1/subscriptions/:id/entitlements`, which is what
# `guard` and any other consumer will gate a feature on. A shape this loose would
# let `features: "dashboards"` through, and `Array("dashboards")` renders it as
# `["dashboards"]` — a string that happens to be the right one, on a field where
# somebody will eventually write `features.first.end_with?`.
#
# So the shape is closed here, at the only place a plan is written, rather than
# guessed at by each reader.
class PlanEntitlementsTest < ActiveSupport::TestCase
  VALID_CASES = {
    "nothing at all" => {},
    "features only" => { "features" => %w[dashboards exports] },
    "features and limits" => { "features" => %w[dashboards], "limits" => { "seats" => 5 } },
    "a zero limit" => { "limits" => { "exports_per_day" => 0 } },
    "no features" => { "features" => [] },
    "no limits" => { "limits" => {} }
  }.freeze

  VALID_CASES.each do |name, entitlements|
    test "accepts #{name}" do
      plan = build_plan(entitlements)

      assert_predicate plan, :valid?
    end
  end

  REFUSED_CASES = {
    "a scalar" => "dashboards",
    "an array" => %w[dashboards],
    "features that is not an array" => { "features" => "dashboards" },
    "features that is a hash" => { "features" => { "dashboards" => true } },
    "a feature that is not a string" => { "features" => [ 1 ] },
    "a blank feature" => { "features" => [ "" ] },
    "a feature that is only whitespace" => { "features" => [ " " ] },
    "a feature with no shape at all" => { "features" => [ nil ] },
    "limits that is not an object" => { "limits" => [ 1 ] },
    "a limit that is not a whole number" => { "limits" => { "seats" => 1.5 } },
    "a limit that is negative" => { "limits" => { "seats" => -1 } },
    "a limit that is a string" => { "limits" => { "seats" => "5" } }
  }.freeze

  REFUSED_CASES.each do |name, entitlements|
    test "refuses #{name}" do
      plan = build_plan(entitlements)

      assert_not plan.valid?
      assert_includes plan.errors.attribute_names, :entitlements
    end
  end

  test "an unknown key is refused, because a reader would ignore it" do
    plan = build_plan("features" => %w[dashboards], "seats" => 5)

    assert_not plan.valid?
  end

  test "a nil is normalised to the empty object, so the wire shape is one shape" do
    plan = build_plan(nil)
    plan.validate

    assert_equal({}, plan.entitlements)
  end

  test "it is carried on the wire, because it is what the entitlements endpoint reads" do
    plan = Plan.create!(
      name: "Pro monthly", slug: "pro-monthly", price: Billing::Money.new(1900, "USD"), interval: "month",
      entitlements: { "features" => %w[dashboards] }
    )

    assert_equal({ "features" => %w[dashboards] }, plan.as_json.fetch("entitlements"))
  end

  test "a plan that was written before the column existed reads as granting nothing" do
    plan = Plan.create!(name: "Pro", slug: "pro", price: Billing::Money.new(1900, "USD"), interval: "month")

    assert_equal({}, plan.entitlements)
  end

  # Written as SQL rather than as a model with validations skipped, because skipping
  # them also skips the normalisation that would hide the very mistake this is
  # checking for. The constraint is the wall; this is the test that it is one.
  CONSTRAINT_CASES = {
    "a scalar" => "'\"dashboards\"'::jsonb",
    "an array" => "'[\"dashboards\"]'::jsonb",
    "features that is not an array" => "'{\"features\": \"dashboards\"}'::jsonb",
    "limits that is not an object" => "'{\"limits\": 5}'::jsonb"
  }.freeze

  CONSTRAINT_CASES.each do |name, literal|
    test "the database refuses #{name}, so a row cannot be written around the validation" do
      build_plan({}).save!
      connection = ActiveRecord::Base.lease_connection

      assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("update plans set entitlements = #{literal} where slug = 'pro-monthly'")
      end
    end
  end

  private
    def build_plan(entitlements)
      Plan.new(
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Billing::Money.new(1900, "USD"),
        interval: "month",
        entitlements: entitlements
      )
    end
end
