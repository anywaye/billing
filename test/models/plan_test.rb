require "test_helper"

class PlanTest < ActiveSupport::TestCase
  setup do
    # The clock is injected, not read — see the note in CustomerTest.
    travel_to(frozen_now)

    @plan = Plan.new(
      name: "Pro monthly",
      slug: "pro-monthly",
      price: Billing::Money.new(1900, "USD"),
      interval: "month"
    )
  end

  test "a plan is valid with a name, a slug, a price and an interval" do
    assert @plan.valid?, @plan.errors.full_messages.to_sentence
  end

  # --- one `price_`, one plan -------------------------------------------------
  #
  # The validation behind `plans_processor_price_id_idx`, and the reason the index
  # is not enough on its own: a validation is not a lock, so the index has to be
  # there too — but with only the index a `POST` is answered with a 409 naming no
  # field, and `price` and `processor_price_id` are two different fields a client
  # would then have to guess between. `:taken` is what `ProblemResponses` turns
  # into a named 409, and this is the error it reads.
  test "a second plan may not claim a processor price id that is taken" do
    Plan.create!(name: "Theirs", slug: "theirs", price: Billing::Money.new(4_900, "USD"), interval: "month",
      processor_price_id: "price_FAKEtheirsBBBBBBBBBB")

    @plan.processor_price_id = "price_FAKEtheirsBBBBBBBBBB"

    refute @plan.valid?
    assert @plan.errors.of_kind?(:processor_price_id, :taken),
      "the refusal has to be `:taken` and not a generic `:invalid`, or the 409 stops being a " \
      "conflict and becomes a 422 about a field the client cannot fix"
  end

  test "a processor price id nobody holds is accepted" do
    @plan.processor_price_id = "price_FAKEnobodyhasitBBBBBB"

    assert_predicate @plan, :valid?
  end

  # `allow_nil`, and the reason is that a plan is written through `POST /v1/plans`
  # before it is ever put on sale: many plans are legitimately unsold at once. The
  # rule is "a value here is unique", not "this column is unique" — the same
  # reading the index's partial predicate states.
  test "many plans may carry no processor price id at all" do
    Plan.create!(name: "Draft", slug: "draft", price: Billing::Money.new(900, "USD"), interval: "month")
    unsold = Plan.new(name: "Also a draft", slug: "also-a-draft", price: Billing::Money.new(1_500, "USD"), interval: "month")

    assert_predicate unsold, :valid?
  end

  test "a plan's price is a Billing::Money" do
    assert_kind_of Billing::Money, @plan.price
    assert_equal 1900, @plan.price.minor_units
    assert_equal "USD", @plan.price.currency
  end

  test "a free plan is zero in its own currency" do
    @plan.price = Billing::Money.zero("USD")

    assert @plan.valid?
    assert_equal 0, @plan.price.minor_units
    assert_equal 0, @plan.amount_cents
  end

  test "a plan's price crosses the boundary as minor units, never a float" do
    @plan.save!

    assert_equal 1900, @plan.reload.price.minor_units
    assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, @plan.price.to_h)
  end

  test "a plan's price is refused unless it is a Billing::Money" do
    error = assert_raises(Billing::Money::Error) { @plan.price = 1900 }

    assert_match(/Billing::Money/, error.message)
  end

  test "assigning a Billing::Money writes both the amount and the currency" do
    @plan.price = Billing::Money.new(500, "JPY")

    assert_equal 500, @plan.amount_cents
    assert_equal "JPY", @plan.currency
  end

  test "a negative price is refused" do
    @plan.amount_cents = -1

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :amount_cents
  end

  test "a plan requires a name" do
    @plan.name = "  "

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :name
  end

  test "a plan requires a slug" do
    @plan.slug = nil

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :slug
  end

  test "a plan slug is kebab-case, so it can be a URL segment" do
    @plan.slug = "Pro Monthly"

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :slug
  end

  test "a plan slug cannot carry a slash or start with a dash" do
    [ "/pro-monthly", "-pro", "pro-", "pro--monthly", "pro_monthly" ].each do |slug|
      @plan.slug = slug

      assert_not @plan.valid?, "#{slug.inspect} should not be a valid slug"
    end
  end

  test "a plan slug is unique" do
    @plan.save!
    duplicate = Plan.new(name: "Pro yearly", slug: "pro-monthly", price: Billing::Money.new(1900, "USD"), interval: "year")

    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :slug
  end

  test "a plan currency is an ISO 4217 code" do
    @plan.currency = "dollars"

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :currency
  end

  test "a plan currency is normalised to upper case" do
    @plan.currency = "usd"

    assert @plan.valid?
    assert_equal "USD", @plan.currency
  end

  test "a plan requires an interval" do
    @plan.interval = nil

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :interval
  end

  test "a plan interval is one of the three billing cadences" do
    [ "month", "year", "one_time" ].each do |interval|
      @plan.interval = interval

      assert @plan.valid?, "#{interval} should be a valid interval"
    end
  end

  test "a plan interval is not a fortnight" do
    @plan.interval = "fortnight"

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :interval
  end

  test "a plan is active with no trial unless it says otherwise" do
    assert @plan.active
    assert_equal 0, @plan.trial_days
  end

  test "a plan can carry a trial" do
    @plan.trial_days = 14

    assert @plan.valid?
    assert_equal 14, @plan.trial_days
  end

  test "a trial cannot be negative" do
    @plan.trial_days = -1

    assert_not @plan.valid?
    assert_includes @plan.errors.attribute_names, :trial_days
  end

  test "a plan can be deactivated" do
    @plan.active = false

    assert @plan.valid?
  end

  test "a plan is not yet a Stripe product" do
    @plan.save!

    assert_nil @plan.reload.processor_product_id
    assert_nil @plan.processor_price_id
  end

  test "the wire shape nests the price and is stable" do
    @plan.save!

    assert_equal(
      {
        "id" => @plan.id,
        "name" => "Pro monthly",
        "slug" => "pro-monthly",
        "processor_product_id" => nil,
        "processor_price_id" => nil,
        "price" => { "amount_minor" => 1900, "currency" => "USD" },
        "interval" => "month",
        "trial_days" => 0,
        "entitlements" => {},
        "active" => true,
        "created_at" => frozen_now.iso8601,
        "updated_at" => frozen_now.iso8601
      },
      @plan.as_json
    )
  end
end
