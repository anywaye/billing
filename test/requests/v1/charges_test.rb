require "test_helper"

class V1ChargesTest < ActionDispatch::IntegrationTest
  ACCOUNT_ID = TestSupport::TestIdentity::Account

  OTHER_ACCOUNT_ID = "22222222-2222-4222-8222-222222222222"

  MISSING_UUID = "99999999-9999-4999-8999-999999999999".freeze

  setup do
    travel_to(frozen_now)

    @customer = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEchargesrequestAAAAAAAAA"
    )
    @charge = Charge.create!(
      account_id: ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargesrequestAAAAAAAAA",
      amount: 1_900, currency: "USD", description: "Pro monthly", paid_at: frozen_now
    )
  end


  test "GET /v1/charges lists this account's charges, newest first" do
    travel_to(frozen_now + 1.minute)
    Charge.create!(
      account_id: ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargesrequestBBBBBBBBB",
      amount: 4900, currency: "USD", description: "Team monthly", paid_at: frozen_now + 1.minute
    )

    get "/v1/charges"

    assert_response :ok
    body = json_body
    assert_equal 2, body.fetch("data").size
    assert_equal "ch_FAKEchargesrequestBBBBBBBBB", body.fetch("data").first.fetch("processor_charge_id")
    assert_equal @charge.id, body.fetch("data").last.fetch("id")
    assert_equal @charge.created_at.utc.iso8601, body.fetch("data").last.fetch("created_at")
    assert_equal false, body.fetch("page").fetch("has_more")
    assert_nil body.fetch("page").fetch("next_cursor")
  end

  test "GET /v1/charges does not list another account's charges" do
    Charge.create!(
      account_id: OTHER_ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargesrequestBBBBBBBBB",
      amount: 4900, currency: "USD", description: "Team monthly", paid_at: frozen_now
    )

    get "/v1/charges"

    ids = json_body.fetch("data").map { |row| row.fetch("processor_charge_id") }
    assert_equal [ "ch_FAKEchargesrequestAAAAAAAAA" ], ids
  end

  test "the index transmits the amount as integer minor units" do
    get "/v1/charges"

    row = json_body.fetch("data").sole
    assert_equal 1900, row.fetch("amount")
    assert_equal "USD", row.fetch("currency")
  end

  test "GET /v1/charges is a 401 with no token" do
    without_token!

    get "/v1/charges"

    assert_response :unauthorized
    assert_problem "unauthorized"
  end


  test "GET /v1/charges/:id renders the receipt as HTML" do
    get "/v1/charges/#{@charge.id}"

    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_includes response.body, "Receipt"
  end

  test "the receipt shows the amount as a person reads money" do
    get "/v1/charges/#{@charge.id}"

    assert_includes response.body, "19.00 USD"
  end

  test "the receipt escapes the description" do
    @charge.update!(description: "<script>alert('xss')</script>")

    get "/v1/charges/#{@charge.id}"

    assert_includes response.body, "&lt;script&gt;"
    refute_includes response.body, "<script>alert"
  end

  test "the receipt carries the processor's own charge id" do
    get "/v1/charges/#{@charge.id}"

    assert_includes response.body, "ch_FAKEchargesrequestAAAAAAAAA"
  end


  test "GET /v1/charges/:id is a 404 for another account's charge" do
    other = Charge.create!(
      account_id: OTHER_ACCOUNT_ID, customer: @customer,
      processor_charge_id: "ch_FAKEchargesrequestBBBBBBBBB",
      amount: 1_900, currency: "USD", description: "Pro monthly", paid_at: frozen_now
    )

    get "/v1/charges/#{other.id}"
    another_accounts = problem_without_request_echo

    assert_response :not_found

    get "/v1/charges/#{MISSING_UUID}"
    missing = problem_without_request_echo

    assert_equal missing, another_accounts,
      "another account's charge and a uuid that names nothing must be one answer. They " \
      "differ in: #{(missing.keys | another_accounts.keys).reject { |key| missing[key] == another_accounts[key] }.inspect}"
  end

  test "GET /v1/charges/:id is a 404 for an id that does not exist" do
    get "/v1/charges/#{MISSING_UUID}"

    assert_response :not_found
    assert_problem "not_found"
  end

  test "GET /v1/charges/:id is a 404 for an id that is not an id" do
    get "/v1/charges/someone-elses-charge"

    assert_response :not_found
    assert_problem "not_found"
  end


  test "GET /v1/charges/:id is a 401 with no token" do
    without_token!

    get "/v1/charges/#{@charge.id}"

    assert_response :unauthorized
    assert_problem "unauthorized"
  end

  private
    def problem_without_request_echo
      json_body.except("trace_id", "instance")
    end
end
