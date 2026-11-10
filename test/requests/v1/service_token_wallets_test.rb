require "test_helper"

class V1ServiceTokenWalletsTest < ActionDispatch::IntegrationTest
  SERVICE_TOKEN = "test-service-token"
  OWNER_KEY = "boax_org_1"

  setup do
    travel_to(frozen_now)
    @previous_token = ENV["BILLING_SERVICE_TOKEN"]
    ENV["BILLING_SERVICE_TOKEN"] = SERVICE_TOKEN
    with_authorization_header("Bearer #{SERVICE_TOKEN}")
  end

  teardown do
    ENV["BILLING_SERVICE_TOKEN"] = @previous_token
  end

  test "GET returns a zero balance for a new owner" do
    get "/v1/service/token_wallets/#{OWNER_KEY}"

    assert_response :ok
    assert_equal OWNER_KEY, json_body.fetch("owner_key")
    assert_equal 0, json_body.fetch("balance")
  end

  test "grant then deduct moves the balance" do
    post "/v1/service/token_wallets/#{OWNER_KEY}/grant", params: { amount: 10, reason: "welcome" }, as: :json
    assert_response :created
    assert_equal 10, json_body.fetch("balance")

    post "/v1/service/token_wallets/#{OWNER_KEY}/deduct", params: { amount: 3, reason: "sandbox" }, as: :json
    assert_response :ok
    assert_equal 7, json_body.fetch("balance")
  end

  test "a wrong service token is a 401" do
    with_authorization_header("Bearer wrong")

    get "/v1/service/token_wallets/#{OWNER_KEY}"

    assert_response :unauthorized
    assert_problem "unauthorized"
  end

  test "an unset service token is a 503" do
    ENV["BILLING_SERVICE_TOKEN"] = nil

    get "/v1/service/token_wallets/#{OWNER_KEY}"

    assert_response :service_unavailable
    assert_problem "unavailable"
  end
end
