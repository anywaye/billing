require "test_helper"

class V1ProblemEnvelopeTest < ActionDispatch::IntegrationTest
  TRACED = "0af7651916cd43dd8448eb211c80319c"

  setup do
    travel_to(frozen_now)
  end

  test "a successful response carries X-Trace-Id" do
    get "/v1/plans"

    assert_response :ok
    assert_match Identifiers::UUID, trace_id_header
  end

  test "a successful response echoes the caller's trace id" do
    get "/v1/plans", headers: { "X-Trace-Id" => TRACED }

    assert_equal TRACED, trace_id_header
  end

  test "an error response carries the same trace id in the header and the body" do
    get "/v1/plans/enterprise-yearly", headers: { "X-Trace-Id" => TRACED }

    assert_response :not_found
    assert_equal TRACED, trace_id_header
    assert_equal TRACED, json_body.fetch("trace_id")
  end

  test "the type is the machine-readable contract and the code is its last segment" do
    get "/v1/plans/enterprise-yearly"

    assert_equal "https://docs.anywaye.com/errors/not_found", json_body.fetch("type")
    assert_equal "not_found", json_body.fetch("code")
  end

  test "the instance is the path the caller asked for" do
    get "/v1/plans/enterprise-yearly"

    assert_equal "/v1/plans/enterprise-yearly", json_body.fetch("instance")
  end

  test "the envelope answers application/problem+json, never html" do
    get "/v1/plans/enterprise-yearly"

    assert_equal "application/problem+json", media_type
  end

  test "a path that is not part of the api is a problem+json 404, not an html page" do
    get "/v1/widgets"

    assert_response :not_found
    assert_problem "not_found"
    assert_equal "application/problem+json", media_type
  end

  test "a body that is not json is a 400, because the client could not have known" do
    post "/v1/plans", params: "{ not json", headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    assert_problem "bad_request"
    assert_equal 0, Plan.count
  end

  test "a 422 lists the fields that failed and no other" do
    post "/v1/plans", params: { name: "Pro monthly" }, as: :json

    assert_equal [ "interval", "price", "slug" ], json_body.fetch("errors").pluck("field").sort
    assert_equal 422, json_body.fetch("status")
  end

  test "the detail names the specific failure and is not a generic apology" do
    post "/v1/plans", params: { name: "Pro monthly" }, as: :json

    assert_match(/price/, json_body.fetch("detail"))
    assert_equal json_body.fetch("errors").size, json_body.fetch("detail").scan(/price|interval|slug/).size
  end

  test "a title is present for a client that shows it to a human" do
    get "/v1/plans/enterprise-yearly"

    assert_equal "Not found", json_body.fetch("title")
  end

  test "an internal failure does not return its cause to the caller" do
    problem = Problem.new(code: :internal, detail: Problem::INTERNAL_DETAIL, trace_id: TRACED, instance: "/v1/plans")

    assert_equal 500, problem.status
    assert_equal Problem::INTERNAL_DETAIL, problem.to_h.fetch("detail")
    assert_no_match(/PG::|ActiveRecord::|no such table/, problem.to_h.to_json)
  end

  test "an internal failure logs the cause with the id needed to find the row" do
    logged = capture_log do
      Problem.new(
        code: :internal,
        detail: Problem::INTERNAL_DETAIL,
        trace_id: TRACED,
        instance: "/v1/plans",
        cause: ArgumentError.new("something specific went wrong in plan 42")
      ).log_cause
    end

    assert_match(/ArgumentError/, logged)
    assert_match(/something specific went wrong in plan 42/, logged)
  end
end
