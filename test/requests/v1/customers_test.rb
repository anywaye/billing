require "test_helper"

class V1CustomersTest < ActionDispatch::IntegrationTest
  OWNER_ID = TestSupport::TestIdentity::Account

  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222"

  IDEMPOTENCY_KEY = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

  setup do
    travel_to(frozen_now)
  end


  test "POST /v1/customers creates a customer and returns it" do
    post "/v1/customers",
      params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" },
      as: :json

    assert_response :created
    customer = Customer.sole
    assert_equal({ "type" => "Account", "id" => OWNER_ID }, json_body.fetch("owner"))
    assert_equal "stripe", json_body.fetch("processor")
    assert_nil json_body.fetch("processor_customer_id")
    assert_equal customer.id, json_body.fetch("id")
    assert_equal frozen_now.iso8601, json_body.fetch("created_at")
    assert_equal "/v1/customers/#{customer.id}", response.headers["Location"]
  end

  test "POST /v1/customers emits billing.customer.created in the same transaction" do
    post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }, as: :json

    assert_response :created
    event = OutboxEvent.sole
    assert_equal "billing.customer.created", event.event_type
    assert_equal json_body.fetch("id"), event.subject
  end

  test "POST /v1/customers is a 409 when the owner already has one on that processor" do
    create_customer

    assert_no_difference [ "Customer.count", "OutboxEvent.count" ] do
      post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }, as: :json
    end

    assert_response :conflict
    assert_problem "conflict"
  end

  test "POST /v1/customers is a 409 on another account's processor customer id" do
    other_accounts = Customer.create!(
      owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEsomebodyelseBBBBBBBBBB"
    )

    post "/v1/customers",
      params: { processor: "stripe", processor_customer_id: other_accounts.processor_customer_id },
      as: :json

    assert_response :conflict
    assert_problem "conflict"
    assert_match(/processor_customer_id/, response.body,
      "the 409 must name the field. The caller holds no customer at all, so the only thing this " \
      "request collides with is that id, and a 409 that did not say so would send a client " \
      "looking for a collision that is not there.")
  end

  test "a refused processor customer id leaves the caller's own row untouched" do
    victim = Customer.create!(
      owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEvictimBBBBBBBBBBBBB"
    )
    caller = create_customer(processor_customer_id: "cus_FAKEcallerAAAAAAAAA")

    patch "/v1/customers/#{caller.id}",
      params: { processor_customer_id: victim.processor_customer_id },
      as: :json

    assert_response :conflict
    assert_match(/processor_customer_id/, response.body)
    assert_equal "cus_FAKEcallerAAAAAAAAA", caller.reload.processor_customer_id,
      "the refused field was written anyway"
    assert_equal "cus_FAKEvictimBBBBBBBBBBBBB", victim.reload.processor_customer_id
  end

  test "PATCH /v1/customers/:id accepts a processor customer id nobody holds" do
    customer = create_customer(processor_customer_id: "cus_FAKEmineAAAAAAAAAA")

    patch "/v1/customers/#{customer.id}",
      params: { processor_customer_id: "cus_FAKEnewoneBBBBBBBBBBBB" },
      as: :json

    assert_response :ok
    assert_equal "cus_FAKEnewoneBBBBBBBBBBBB", customer.reload.processor_customer_id
  end

  test "PATCH /v1/customers/:id accepts setting the processor customer id to the value it already holds" do
    customer = create_customer(processor_customer_id: "cus_FAKEsameAAAAAAAAAAA")

    patch "/v1/customers/#{customer.id}",
      params: { processor_customer_id: "cus_FAKEsameAAAAAAAAAAA" },
      as: :json

    assert_response :ok
    assert_equal "cus_FAKEsameAAAAAAAAAAA", customer.reload.processor_customer_id
  end

  test "POST /v1/customers is a 422 for a field the client got wrong" do
    post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal [ "email" ], problem_codes
    assert_equal "invalid_format", json_body.fetch("errors").sole.fetch("code")
  end

  test "POST /v1/customers reports every bad field, not just the first" do
    post "/v1/customers", params: { owner_type: "Widget", owner_id: "nope", processor: "braintree", email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_equal %w[email processor], problem_codes.sort
  end

  test "POST /v1/customers ignores the body's owner entirely, valid or not" do
    post "/v1/customers",
      params: { owner_type: "Widget", owner_id: "not-a-uuid", processor: "stripe" },
      as: :json

    assert_response :created
    assert_equal "Account", json_body.dig("owner", "type")
    assert_equal OWNER_ID, json_body.dig("owner", "id")
    assert_equal OWNER_ID, Customer.sole.owner_id
  end

  test "POST /v1/customers with no body is a 422, not a 500" do
    post "/v1/customers", params: {}, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
  end


  test "GET /v1/customers returns this account's customer" do
    mine = create_customer

    get "/v1/customers"

    assert_response :ok
    assert_equal [ mine.id ], json_body.fetch("data").pluck("id")
    assert_equal({ "next_cursor" => nil, "has_more" => false }, json_body.fetch("page"))
  end

  test "GET /v1/customers returns an empty array rather than nothing" do
    get "/v1/customers"

    assert_response :ok
    assert_equal [], json_body.fetch("data")
  end

  test "GET /v1/customers is a 422 for a limit that is not a count" do
    get "/v1/customers", params: { limit: "all" }

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
  end

  test "GET /v1/customers is a 400 for a cursor it cannot read" do
    get "/v1/customers", params: { cursor: "not-base64url" }

    assert_response :bad_request
    assert_problem "cursor_invalid"
  end

  test "GET /v1/customers cannot overflow a page, because one customer per account per processor is unique" do
    create_customer

    second = Customer.new(owner_type: "Account", owner_id: OWNER_ID, processor: "stripe")
    assert_raises(ActiveRecord::RecordNotUnique) do
      second.save!(validate: false)
    end

    get "/v1/customers"

    assert_response :ok
    assert_equal 1, json_body.fetch("data").size
    refute json_body.dig("page", "has_more"),
      "the listing reports more pages, so it believes it holds rows this account cannot have"
  end


  test "GET /v1/customers/:id round-trips what POST created" do
    created = post_customer

    get "/v1/customers/#{created.fetch("id")}"

    assert_response :ok
    assert_equal created, json_body
  end

  test "GET /v1/customers/:id is a 404 for an id that does not exist" do
    get "/v1/customers/99999999-9999-4999-8999-999999999999"

    assert_response :not_found
    assert_problem "not_found"
  end

  test "GET /v1/customers/:id is a 404 for an id that is not an id" do
    get "/v1/customers/someone-elses-customer"

    assert_response :not_found
    assert_problem "not_found"
  end


  test "PATCH /v1/customers/:id updates the customer" do
    customer = create_customer

    patch "/v1/customers/#{customer.id}", params: { email: "new@example.com" }, as: :json

    assert_response :ok
    assert_equal "new@example.com", json_body.fetch("email")
    assert_equal "new@example.com", customer.reload.email
  end

  test "PATCH /v1/customers/:id leaves the fields it was not given alone" do
    create_customer(email: "kaka@example.com", metadata: { "tenant" => "kaka" })

    patch "/v1/customers/#{Customer.sole.id}", params: { email: "new@example.com" }, as: :json

    assert_equal({ "tenant" => "kaka" }, json_body.fetch("metadata"))
  end

  test "PATCH /v1/customers/:id is a 422 for a bad field" do
    customer = create_customer

    patch "/v1/customers/#{customer.id}", params: { email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal "kaka@example.com", customer.reload.email
  end

  test "PATCH /v1/customers/:id is a 404 for an id that does not exist" do
    patch "/v1/customers/99999999-9999-4999-8999-999999999999", params: { email: "new@example.com" }, as: :json

    assert_response :not_found
    assert_problem "not_found"
  end

  test "PATCH /v1/customers/:id emits no event, because the packet defines none for it" do
    customer = create_customer
    last_event

    assert_no_difference("OutboxEvent.count") do
      patch "/v1/customers/#{customer.id}", params: { email: "new@example.com" }, as: :json
    end
  end


  test "POST /v1/customers replays the original response for the same key and body" do
    post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    assert_response :created
    original = json_body

    assert_no_difference [ "Customer.count", "OutboxEvent.count" ] do
      post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    end

    assert_response :created
    assert_equal original, json_body
    assert_equal "true", response.headers["Idempotency-Replayed"]
  end

  test "POST /v1/customers is a 409 when a key is reused for a different body" do
    post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    assert_response :created

    post "/v1/customers", params: customer_params.merge(email: "other@example.com"), headers: idempotency_headers, as: :json

    assert_response :conflict
    assert_problem "idempotency_key_reused"
  end

  test "POST /v1/customers without a key is processed normally" do
    post "/v1/customers", params: customer_params, as: :json

    assert_response :created
    assert_nil response.headers["Idempotency-Replayed"]
  end

  private
    def customer_params
      { owner_type: "Account", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }
    end

    def idempotency_headers
      { "Idempotency-Key" => IDEMPOTENCY_KEY }
    end

    def create_customer(overrides = {})
      travel 1.second

      Customer.create!({ owner_type: "Account", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }.merge(overrides))
    end

    def post_customer
      post "/v1/customers", params: customer_params, as: :json
      assert_response :created
      json_body
    end

    def last_event
      OutboxEvent.order(:created_at, :id).last
    end
end
