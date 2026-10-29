require "test_helper"

class TenantCrossAccountWebTest < ActionDispatch::IntegrationTest
  MISSING_UUID = "99999999-9999-4999-8999-999999999999".freeze

  CALLER = TestSupport::TestIdentity::Account

  THIRD_ACCOUNT = "55555555-5555-4555-8555-555555555555".freeze

  class << self
    def negative_test_methods
      public_instance_methods(false).grep(/\Atest_/).reject { |method| method.to_s.start_with?("test_meta:") }.sort
    end
  end

  SENTINEL_EMAIL = "account-b-sentinel@example.invalid".freeze

  REWRITTEN_EMAIL = "account-b-rewritten@example.invalid".freeze

  setup do
    travel_to(frozen_now)
    create_account_customers
    create_account_subscriptions
    customer_b.update!(email: SENTINEL_EMAIL)
    @caller_customer = Customer.create!(
      owner_type: "Account", owner_id: CALLER, processor: "stripe",
      processor_customer_id: "cus_FAKEcallerAAAAAAAAA", email: "caller@example.com"
    )
    @caller_subscription = Subscription.create!(
      account_id: CALLER, customer: @caller_customer, plan: shared_plan,
      processor_subscription_id: "sub_FAKEcallerAAAAAAAAAA", status: "active"
    )
    acts_as(CALLER)
  end


  ADDRESSED_BY_UUID = [
    [ "a customer", ->(id) { "/v1/customers/#{id}" } ],
    [ "a plan", ->(id) { "/v1/plans/#{id}" } ],
    [ "a subscription", ->(id) { "/v1/subscriptions/#{id}" } ]
  ].freeze

  ADDRESSED_BY_UUID.each do |label, path_for|
    test "read: #{label} answers a missing uuid and an impossible id identically" do
      get path_for.call(MISSING_UUID)
      missing = problem_without_request_echo

      assert_response :not_found
      assert_problem "not_found"

      get path_for.call("not-a-uuid")
      impossible = problem_without_request_echo

      assert_response :not_found
      assert_problem "not_found"
      assert_equal missing, impossible,
        "a #{label} that does not exist and an id that cannot name one must be the same " \
        "answer. They differ in: #{(missing.keys | impossible.keys).reject { |key| missing[key] == impossible[key] }.inspect}"
    end
  end

  test "read: a plan answers a slug nobody wrote and a uuid nobody wrote identically" do
    get "/v1/plans/no-such-plan-ever"
    by_slug = problem_without_request_echo
    assert_response :not_found

    get "/v1/plans/#{MISSING_UUID}"
    by_uuid = problem_without_request_echo
    assert_response :not_found

    assert_equal by_slug, by_uuid,
      "a plan addressed two different ways must be absent in the same way. They differ in: " \
      "#{(by_slug.keys | by_uuid.keys).reject { |key| by_slug[key] == by_uuid[key] }.inspect}"
  end

  ADDRESSED_BY_UUID.each do |label, path_for|
    test "read: the 404 for #{label} carries the caller's own path and one fixed sentence" do
      get path_for.call(MISSING_UUID)

      assert_response :not_found
      assert_equal %w[code detail instance status title trace_id type], json_body.keys.sort,
        "the 404's shape changed. A field this list does not name is a field that could " \
        "carry something about the resource it refused."
      assert_equal "No record matches that identifier.", json_body["detail"],
        "the 404's detail now says something specific. Two sentences is the shape of an " \
        "enumeration oracle: one for 'does not exist' and one for 'exists, not yours'."
      assert_equal path_for.call(MISSING_UUID), json_body["instance"],
        "`instance` is the caller's own request path. It echoes input the caller already " \
        "has, which is safe; it must never carry anything the caller did not send."
      refute response.body.include?(SENTINEL_EMAIL),
        "a 404 carried a customer's address. The absent case must be absent in full."
    end
  end


  test "read: this service cannot emit a 403, so it cannot be an enumeration oracle" do
    statuses = Problem::CATALOG.values.map { |entry| Rack::Utils.status_code(entry.fetch(:status)) }

    refute_includes statuses, 403,
      "a 403 was added to the problem vocabulary. A 403 on a resource the caller cannot " \
      "see distinguishes it from one that does not exist, which is exactly the " \
      "enumeration oracle this service must not have. Use 404, or nil at the query."
    assert_equal statuses.uniq.sort, [ 400, 401, 402, 404, 409, 422, 500, 503 ],
      "the problem vocabulary's statuses changed. 401 is `unauthorized`, added in billing-21 " \
      "for the token check, and is about the caller. This service answers 404 for absence, " \
      "never 403."
  end

  test "read: the 401 is `unauthorized`, which is core's reserved code" do
    entry = Problem::CATALOG.fetch(:unauthorized)

    assert_equal :unauthorized, entry.fetch(:status)
    assert_equal 401, Rack::Utils.status_code(entry.fetch(:status))
    assert_operator Problem::CATALOG.keys, :include?, :unauthorized
  end

  test "read: no controller renders a 403 by any route" do
    offenders = app_sources.select { |path, source|
      source.lines.reject { |line| line.strip.start_with?("#") }.any? { |line| line.match?(/\b403\b|forbidden/i) }
    }

    assert_empty offenders.keys,
      "these files write a 403 or `forbidden` in code. Absence is not refusal: a resource the " \
      "caller may not see must be indistinguishable from one that does not exist. Offenders: " \
      "#{offenders.keys.inspect}"
  end

  test "read: the 403 scan reads every file under app/ rather than a list" do
    assert_operator app_sources.size, :>=, 40,
      "the scan found far fewer files than app/ has. A scan over a short list is a scan over " \
      "a list somebody maintained."
  end


  test "read: another account's customer is a 404, and is the same answer as a uuid that names nothing" do
    get "/v1/customers/#{customer_b.id}"
    another_accounts = problem_without_request_echo
    assert_response :not_found

    get "/v1/customers/#{MISSING_UUID}"
    missing = problem_without_request_echo
    assert_response :not_found

    assert_equal missing, another_accounts,
      "another account's customer and a uuid that names nothing must be one answer. They " \
      "differ in: #{(missing.keys | another_accounts.keys).reject { |key| missing[key] == another_accounts[key] }.inspect}"
    refute response.body.include?(SENTINEL_EMAIL),
      "the refusal carried account B's customer's address. The absent case must be absent in full."
  end

  test "read: another account's subscription is a 404" do
    get "/v1/subscriptions/#{subscription_b.id}"
    another_accounts = problem_without_request_echo
    assert_response :not_found

    get "/v1/subscriptions/#{MISSING_UUID}"
    missing = problem_without_request_echo
    assert_response :not_found

    assert_equal missing, another_accounts,
      "another account's subscription must be absent in the same way as one that does not exist"
  end

  test "read: another account's entitlements are a 404" do
    get "/v1/subscriptions/#{subscription_b.id}/entitlements"

    assert_response :not_found
    refute_includes [ 200 ], response.status,
      "the entitlements read was not refused"
    refute response.body.include?("granted"),
      "the refusal leaked an entitlements body. A refused read must be the same document every " \
      "other refusal is."
  end

  test "update: another account's customer cannot be written by its uuid alone" do
    before = fingerprint([ customer_b ])

    patch "/v1/customers/#{customer_b.id}", params: { email: REWRITTEN_EMAIL }, as: :json

    assert_response :not_found,
      "the PATCH was answered #{response.status}. A write to another account's customer must " \
      "be a 404 — the same answer a uuid naming nothing gets, and never a 403."
    assert_empty drifted_ids(before, [ customer_b ]),
      "the PATCH named only account B's uuid and B's row changed. `Customer.for_account` must " \
      "constrain the lookup, not merely the listing."
    refute response.body.include?(REWRITTEN_EMAIL),
      "the refusal echoed the value the write carried."
  end

  test "update: another account's subscription cannot be cancelled by its uuid alone" do
    previous = Processor::StripeClient.current
    api = FakeStripeAPI.new
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: api)
    before = fingerprint([ subscription_b ])

    post "/v1/subscriptions/#{subscription_b.id}/cancel", params: { at_period_end: true }, as: :json

    assert_response :not_found
    assert_empty api.requests,
      "the processor was asked to cancel a subscription the caller may not see. The scope is " \
      "the resolution, not the request: this must 404 before `cancel_subscription` is called."
    assert_empty drifted_ids(before, [ subscription_b ])
  ensure
    Processor::StripeClient.current = previous
  end

  test "update: another account's subscription cannot be moved onto another plan by its uuid alone" do
    previous = Processor::StripeClient.current
    api = FakeStripeAPI.new
    Processor::StripeClient.current = Processor::StripeClient.new(api_key: "sk_test", api: api)

    post "/v1/subscriptions/#{subscription_b.id}/change_plan",
      params: { plan_id: shared_plan.id }, as: :json

    assert_response :not_found
    assert_empty api.requests,
      "the processor was asked to move a subscription the caller may not see."
  ensure
    Processor::StripeClient.current = previous
  end

  test "list: a subscription listing carries this account's rows and omits the other's" do
    get "/v1/subscriptions"

    assert_response :ok
    listed = json_body.fetch("data").map { |row| row.fetch("id") }

    assert_includes listed, @caller_subscription.id,
      "the caller's own subscription is missing from its own listing, so this test would pass " \
      "against a listing that returned nothing."
    refute_includes listed, subscription_b.id,
      "another account's subscription is in the listing. `Subscription.for_account` must " \
      "constrain `index` and not only the row-addressed actions."
  end

  test "list: a customer listing carries this account's rows and omits the other's" do
    get "/v1/customers"

    assert_response :ok
    listed = json_body.fetch("data").map { |row| row.fetch("id") }

    assert_includes listed, @caller_customer.id
    refute_includes listed, customer_b.id
    refute response.body.include?(SENTINEL_EMAIL),
      "the listing carried account B's customer's address. A scoped listing that leaked one " \
      "row is worse than an unscoped one nobody reads."
  end

  test "list: a User-owned customer is in no account's listing" do
    user_customer = Customer.create!(
      owner_type: "User", owner_id: SecureRandom.uuid, processor: "stripe",
      processor_customer_id: "cus_FAKEuserBBBBBBBBBBBBB"
    )

    get "/v1/customers"

    assert_response :ok
    refute_includes json_body.fetch("data").map { |row| row.fetch("id") }, user_customer.id,
      "a User-owned customer appeared in an account's listing. It belongs to no account, so " \
      "there is nothing to scope it by and no caller may be shown it."

    get "/v1/customers/#{user_customer.id}"
    assert_response :not_found
  end

  test "write: a customer created through /v1 is owned by the token's account, not by the body" do
    acts_as(THIRD_ACCOUNT)

    post "/v1/customers",
      params: { owner_type: "Account", owner_id: TwoAccounts::ACCOUNT_A, processor: "stripe" },
      as: :json

    assert_response :created
    assert_equal THIRD_ACCOUNT, json_body.dig("owner", "id"),
      "the customer was created for the owner named in the body. The account comes from the " \
      "token and the body field is ignored — honouring it would let any authenticated caller " \
      "mint a customer owned by another tenant."
    assert_equal "Account", json_body.dig("owner", "type")
    assert_empty Customer.where(owner_id: TwoAccounts::ACCOUNT_A).where.not(id: customer_a.id),
      "a customer was written for account A, which already held one. The 201 above is for " \
      "somebody else and this row is the write the body asked for."
  end


  test "meta: this file holds 21 negative tests" do
    assert_equal 21, self.class.negative_test_methods.size
  end

  test "meta: the account-constrained queries are exactly the three scopes and their callers" do
    assert_equal 6, account_scoped_queries,
      "the account-constrained queries in app/ are not the ones this file's tests are about. " \
      "`Subscription.for_account`, `Customer.for_account` or `Charge.for_account` has been " \
      "renamed or removed, which means the rewritten tests above are asserting a boundary the " \
      "code no longer has. Measured: 3 named scopes + 3 inline `where`/`find_by` constraints. " \
      "The checkout door's own scoping is a call to the named `Customer.for_account` scope, so " \
      "it is not one of these three — it is held by the file list below instead, where a call " \
      "that appears somewhere the boundary does not reach fails by name."
    assert_empty app_sources.select { |_path, source|
      source.lines.reject { |line| line.strip.start_with?("#") }.any? { |line| line.match?(/\.for_account\b/) }
    }.map { |path, _source| path } - %w[
      app/models/charge.rb
      app/models/customer.rb
      app/models/subscription.rb
      app/controllers/v1/charges_controller.rb
      app/controllers/v1/checkouts_controller.rb
      app/controllers/v1/customers_controller.rb
      app/controllers/v1/subscriptions_controller.rb
    ].then { |unexpected| unexpected },
      "a `for_account` scope appeared somewhere the boundary does not reach. That is a new " \
      "account-scoped entry point and the entry-point matrix must classify it."
  end

  private
    def problem_without_request_echo
      json_body.except("trace_id", "instance")
    end

    def account_scoped_queries
      app_sources.values.sum { |source|
        source.scan(/(?:where|find|find_by|find_by!)\(.*?(?:account_id|owner_id):/).size
      } + app_sources.values.count { |source| source.match?(/scope :for_account\b/) }
    end

    def app_sources
      @app_sources ||= Dir[Rails.root.join("app/**/*.rb")].to_h { |path|
        [ Pathname(path).relative_path_from(Rails.root).to_s, File.read(path) ]
      }
    end
end
