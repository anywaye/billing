require "test_helper"

# GET /v1/charges/:id — the receipt for one charge.
#
# The property that shapes every case here: **the receipt is scoped by the
# token's account, and a cross-tenant read is a 404** — byte for byte the answer
# a uuid naming nothing gets. Not 403: a 403 says "this exists, you may not have
# it", which is an enumeration oracle for anyone walking ids. Absence, never
# refusal.
#
# The receipt is HTML, and that is the one success response on `/v1` that is not
# JSON. Every **error** on it is still `application/problem+json`, with the same
# seven keys as everywhere else — asserted with the shared `assert_problem`
# helper rather than field by field.
class V1ChargesTest < ActionDispatch::IntegrationTest
  # The account these fixtures belong to, and therefore the one the token names.
  # It is **the same value as the authenticated account** and that is the point:
  # every query on `/v1` is scoped by the token's `account_id`, so a fixture owned
  # by a random uuid is invisible to every caller.
  ACCOUNT_ID = TestSupport::TestIdentity::Account

  # A second account, for the case that needs a row belonging to somebody else.
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

  # --- the receipt itself ------------------------------------------------------

  test "GET /v1/charges/:id renders the receipt as HTML" do
    get "/v1/charges/#{@charge.id}"

    assert_response :ok
    assert_equal "text/html", response.media_type
    assert_includes response.body, "Receipt"
  end

  # The amount is formatted with the currency's own exponent, so a yen receipt
  # has no decimal point it has no minor unit for.
  test "the receipt shows the amount as a person reads money" do
    get "/v1/charges/#{@charge.id}"

    assert_includes response.body, "19.00 USD"
  end

  # The description is the processor's own text, HTML-escaped on the way out
  # without exception — a price named `<script>` at the processor must not
  # execute in a page served from this origin.
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

  # --- the tenancy boundary ----------------------------------------------------

  # The rule the whole route exists for. Another account's charge is absent in
  # exactly the way a uuid naming nothing is absent — the same seven-key
  # problem+json body, with no difference a caller could use to tell them apart.
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

  # --- the lock -----------------------------------------------------------------

  # The receipt route is on `/v1`, so it carries the principal lock like every
  # other operation there. A caller with no token gets the same 401 as anywhere
  # else — not a 404, which would tell an unauthenticated caller whether the
  # charge exists.
  test "GET /v1/charges/:id is a 401 with no token" do
    without_token!

    get "/v1/charges/#{@charge.id}"

    assert_response :unauthorized
    assert_problem "unauthorized"
  end

  private
    # The 404 body without the two fields that differ on every request: the trace
    # id and the path echoed in `instance`. Everything else must match exactly.
    def problem_without_request_echo
      json_body.except("trace_id", "instance")
    end
end
