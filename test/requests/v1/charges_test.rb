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

  # --- the index ---------------------------------------------------------------

  # This account's charges, newest first. The index the receipts packet recorded
  # as deliberately absent — "a list nobody can scope safely" — is safe now that
  # every charge carries an account and every query runs through `for_account`,
  # and it is the history a customer asks for when they want to see what they
  # paid and when.
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
    # Two rows on a default page of 25: the last page, and no cursor. A cursor
    # only exists when there is more to fetch, and a client that parsed one
    # would be parsing an implementation detail — which is why the shape is
    # asserted rather than its content.
    assert_equal false, body.fetch("page").fetch("has_more")
    assert_nil body.fetch("page").fetch("next_cursor")
  end

  # The index is scoped like every other row-addressed read on `/v1`, and an
  # absent row is what absent means: another account's charge is not in the
  # listing at all, which is the only scope answer a listing can give.
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

  # The amount crosses as integer minor units, the one representation the whole
  # service uses — the receipt is where a number with a decimal point appears.
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
