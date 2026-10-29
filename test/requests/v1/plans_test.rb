require "test_helper"

class V1PlansTest < ActionDispatch::IntegrationTest
  IDEMPOTENCY_KEY = "9c5b94b1-35ad-49bb-b118-8e8fc24abf80"

  setup do
    travel_to(frozen_now)
  end


  test "POST /v1/plans creates a plan and returns it" do
    post "/v1/plans", params: plan_params, as: :json

    assert_response :created
    plan = Plan.sole
    assert_equal "pro-monthly", json_body.fetch("slug")
    assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, json_body.fetch("price"))
    assert_equal "month", json_body.fetch("interval")
    assert_equal plan.id, json_body.fetch("id")
    assert_equal "/v1/plans/#{plan.id}", response.headers["Location"]
  end

  test "POST /v1/plans emits billing.plan.created" do
    post "/v1/plans", params: plan_params, as: :json

    assert_response :created
    event = OutboxEvent.sole
    assert_equal "billing.plan.created", event.event_type
    assert_equal json_body.fetch("id"), event.subject
  end

  test "POST /v1/plans takes the price in minor units and never a float" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => 19.0, "currency" => "USD" }), as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal [ "price" ], problem_codes
    assert_equal 0, Plan.count
  end

  test "POST /v1/plans refuses a price sent as a decimal string, which is a rounding bug waiting" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => "19.00", "currency" => "USD" }), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "price" ], problem_codes
  end

  test "POST /v1/plans refuses a price that cannot be stored as a bigint" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => 2**64, "currency" => "USD" }), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "price" ], problem_codes
  end

  test "POST /v1/plans is a 422 for a currency that is not an ISO 4217 code" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => 1900, "currency" => "dollars" }), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "price" ], problem_codes
  end

  test "POST /v1/plans normalises the currency it stores" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => 1900, "currency" => "usd" }), as: :json

    assert_response :created
    assert_equal "USD", json_body.dig("price", "currency")
    assert_equal "USD", Plan.sole.currency
  end

  test "POST /v1/plans is a 409 when the slug is taken" do
    create_plan

    assert_no_difference [ "Plan.count", "OutboxEvent.count" ] do
      post "/v1/plans", params: plan_params(name: "Pro monthly again"), as: :json
    end

    assert_response :conflict
    assert_problem "conflict"
  end

  test "POST /v1/plans is a 422 for the fields the client left out" do
    post "/v1/plans", params: { name: "Pro monthly" }, as: :json

    assert_response :unprocessable_entity
    assert_equal %w[interval price slug], problem_codes.sort
  end

  test "POST /v1/plans is a 422 for a slug that is not kebab-case" do
    post "/v1/plans", params: plan_params(slug: "Pro Monthly"), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "slug" ], problem_codes
  end

  test "POST /v1/plans is a 422 for a negative price" do
    post "/v1/plans", params: plan_params(price: { "amount_minor" => -1, "currency" => "USD" }), as: :json

    assert_response :unprocessable_entity
    assert_equal [ "price" ], problem_codes
  end


  test "GET /v1/plans returns a cursor page" do
    create_plan

    get "/v1/plans"

    assert_response :ok
    assert_equal [ "pro-monthly" ], json_body.fetch("data").pluck("slug")
    assert_equal({ "next_cursor" => nil, "has_more" => false }, json_body.fetch("page"))
  end

  test "GET /v1/plans pages without repeating a plan" do
    slugs = 3.times.map { |index| create_plan(slug: "plan-#{index}").slug }

    get "/v1/plans", params: { limit: 2 }
    first_page = json_body.fetch("data").pluck("slug")

    get "/v1/plans", params: { limit: 2, cursor: json_body.dig("page", "next_cursor") }
    second_page = json_body.fetch("data").pluck("slug")

    assert_equal 3, (first_page + second_page).uniq.size
    assert_equal slugs.size, (first_page + second_page).size
  end

  test "GET /v1/plans defaults to 25 rows" do
    bulk_plans(26)

    get "/v1/plans"

    assert_equal 25, json_body.fetch("data").size
    assert json_body.dig("page", "has_more")
  end

  test "GET /v1/plans caps the page at 100 rows" do
    bulk_plans(101)

    get "/v1/plans", params: { limit: 1000 }

    assert_response :ok
    assert_equal 100, json_body.fetch("data").size
    assert json_body.dig("page", "has_more")
  end

  def bulk_plans(count)
    now = frozen_now
    Plan.insert_all(
      count.times.map do |index|
        {
          id: SecureRandom.uuid,
          name: "Bulk #{index}",
          slug: "bulk-#{index}",
          amount_cents: 1900,
          currency: "USD",
          interval: "month",
          entitlements: {},
          created_at: now + index,
          updated_at: now + index
        }
      end
    )
  end


  test "GET /v1/plans/:slug round-trips what POST created" do
    post "/v1/plans", params: plan_params, as: :json
    assert_response :created
    created = json_body

    get "/v1/plans/pro-monthly"

    assert_response :ok
    assert_equal created, json_body
  end

  test "GET /v1/plans/:slug is a 404 for a slug that does not exist" do
    get "/v1/plans/enterprise-yearly"

    assert_response :not_found
    assert_problem "not_found"
  end

  test "GET /v1/plans/:slug is looked up by slug and not by id" do
    plan = create_plan

    get "/v1/plans/#{plan.id}"

    assert_response :not_found
    assert_problem "not_found"
  end


  test "PATCH /v1/plans/:id updates the plan and emits billing.plan.updated" do
    plan = create_plan
    create_event
    travel 1.second

    patch "/v1/plans/#{plan.id}", params: { price: { "amount_minor" => 2500, "currency" => "USD" } }, as: :json

    assert_response :ok
    assert_equal 2500, json_body.dig("price", "amount_minor")
    assert_equal "USD", json_body.dig("price", "currency")
    assert_equal 2500, plan.reload.amount_cents
    assert_equal "billing.plan.updated", OutboxEvent.order(:created_at, :id).last.event_type
  end

  test "PATCH /v1/plans/:id can deactivate a plan without deleting it" do
    plan = create_plan

    patch "/v1/plans/#{plan.id}", params: { active: false }, as: :json

    assert_response :ok
    assert_equal false, json_body.fetch("active")
    assert Plan.exists?(plan.id)
  end

  test "PATCH /v1/plans/:id is a 422 for a float price and changes nothing" do
    plan = create_plan
    create_event

    patch "/v1/plans/#{plan.id}", params: { price: { "amount_minor" => 25.5, "currency" => "USD" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal [ "price" ], problem_codes
    assert_equal 1900, plan.reload.amount_cents
    assert_equal 1, OutboxEvent.count
  end

  test "PATCH /v1/plans/:id is a 409 when the new slug is another plan's" do
    plan = create_plan
    create_plan(slug: "enterprise-yearly")

    patch "/v1/plans/#{plan.id}", params: { slug: "enterprise-yearly" }, as: :json

    assert_response :conflict
    assert_problem "conflict"
  end

  test "POST /v1/plans is a 409 when the processor price id is another plan's" do
    create_plan(processor_price_id: "price_FAKEalreadytakenBBBBBBB")

    assert_no_difference [ "Plan.count", "OutboxEvent.count" ] do
      post "/v1/plans",
        params: plan_params(name: "Cheaper", slug: "cheaper", processor_price_id: "price_FAKEalreadytakenBBBBBBB"),
        as: :json
    end

    assert_response :conflict
    assert_problem "conflict"
    assert_match(/processor_price_id/, response.body)
  end

  test "PATCH /v1/plans/:id is a 409 when the new processor price id is another plan's" do
    plan = create_plan
    other = create_plan(slug: "enterprise-yearly", processor_price_id: "price_FAKEtheirsBBBBBBBBBB")

    patch "/v1/plans/#{plan.id}", params: { processor_price_id: other.processor_price_id }, as: :json

    assert_response :conflict
    assert_problem "conflict"
    assert_nil plan.reload.processor_price_id,
      "the refused field was written anyway"
  end

  test "POST /v1/plans accepts a plan with no processor price id" do
    post "/v1/plans", params: plan_params, as: :json

    assert_response :created
    assert_nil Plan.sole.processor_price_id
  end

  test "PATCH /v1/plans/:id accepts the processor price id it already holds" do
    plan = create_plan(processor_price_id: "price_FAKEsameBBBBBBBBBBBBB")

    patch "/v1/plans/#{plan.id}", params: { processor_price_id: "price_FAKEsameBBBBBBBBBBBBB" }, as: :json

    assert_response :ok
    assert_equal "price_FAKEsameBBBBBBBBBBBBB", plan.reload.processor_price_id
  end

  test "PATCH /v1/plans/:id is a 404 for an id that does not exist" do
    patch "/v1/plans/99999999-9999-4999-8999-999999999999", params: { active: false }, as: :json

    assert_response :not_found
    assert_problem "not_found"
  end

  test "PATCH /v1/plans/:id is addressed by id and not by slug" do
    create_plan

    patch "/v1/plans/pro-monthly", params: { active: false }, as: :json

    assert_response :not_found
    assert_problem "not_found"
  end


  test "POST /v1/plans replays the original response for the same key and body" do
    post "/v1/plans", params: plan_params, headers: { "Idempotency-Key" => IDEMPOTENCY_KEY }, as: :json
    assert_response :created
    original = json_body

    assert_no_difference [ "Plan.count", "OutboxEvent.count" ] do
      post "/v1/plans", params: plan_params, headers: { "Idempotency-Key" => IDEMPOTENCY_KEY }, as: :json
    end

    assert_response :created
    assert_equal original, json_body
    assert_equal "true", response.headers["Idempotency-Replayed"]
  end

  test "POST /v1/plans is a 409 when a key is reused for a different body" do
    post "/v1/plans", params: plan_params, headers: { "Idempotency-Key" => IDEMPOTENCY_KEY }, as: :json

    post "/v1/plans", params: plan_params(interval: "year"), headers: { "Idempotency-Key" => IDEMPOTENCY_KEY }, as: :json

    assert_response :conflict
    assert_problem "idempotency_key_reused"
  end

  private
    def plan_params(overrides = {})
      {
        name: "Pro monthly",
        slug: "pro-monthly",
        price: { "amount_minor" => 1900, "currency" => "USD" },
        interval: "month"
      }.merge(overrides)
    end

    def create_plan(overrides = {})
      travel 1.second

      Plan.create!({
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Billing::Money.new(1900, "USD"),
        interval: "month"
      }.merge(overrides))
    end

    def create_event
      OutboxEvent.sole
    end
end
