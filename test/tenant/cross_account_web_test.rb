require "test_helper"

# Cross-account behaviour on the HTTP surface, and the `403` audit.
#
# # What changed in billing-21, and why the four characterisation tests are gone
#
# billing-12 wrote four `gap:` tests that asserted **another account's row was
# reachable** — a green test saying precisely what was true, coupled to
# `account_scoped_queries` so it would go red the moment scoping landed and say what
# to do about it. That is what happened: billing-21 landed the scoping and those four
# failed with their own instructions.
#
# They are **rewritten, not deleted, and they are the same tests.** Same two accounts
# from `test/support/two_accounts.rb`, same sentinel on account B's row, same `PATCH`,
# same listing — **the assertion is now the opposite one**, and it is worth saying
# what changed rather than only that:
#
#   * A uuid naming another account's row is a **404**, byte for byte the answer a
#     uuid naming nothing gets. The two are compared with `==` in
#     `ADDRESSED_BY_UUID.each` below, which is the strongest statement available: it
#     is not "B's row is hidden" but "B's row is indistinguishable from no row at all".
#   * The `PATCH` **changes nothing**, asserted with `drifted_ids` so the failure
#     names which row moved without printing another account's billing data.
#   * The listing **omits** B's subscription, asserted with `refute_includes` on the
#     id rather than on the payload.
#
# A test that proved the defect could not have been written from scratch after the fix
# without re-deciding what the defect was, and the risk of quietly proving something
# easier is exactly what a regression test is supposed to remove.
#
# # The 403 audit, and the one line it now allows
#
# `Problem::CATALOG` gained `unauthorized` (401) in billing-21 — the token check needs
# one and 401 is core's own reserved code. **It still has no 403**, and that is the
# property this file exists to hold: a caller whose token is good but who named
# another account's row gets the same 404 as one naming nothing, because a 403 says
# "this exists, you may not have it" and a caller walking uuids would learn exactly
# which rows exist without reading one.
#
# The source scan below now matches `403` and `forbidden` rather than
# `403|forbidden|:unauthorized`, and that change is deliberate: `:unauthorized` was
# in the pattern as a proxy for "a status this service must not render", and billing-21
# established that 401 is one it must. What is banned is unchanged and is what the
# scan still looks for.
class TenantCrossAccountWebTest < ActionDispatch::IntegrationTest
  # The two kinds of "no": a uuid that belongs to no row, and a string that is not
  # a uuid and therefore cannot belong to any row. Both must be one answer.
  MISSING_UUID = "99999999-9999-4999-8999-999999999999".freeze

  # The account these tests act **as**. TwoAccounts::ACCOUNT_A is not it: that is the
  # left-hand side of the comparison, and using it for both would make "the caller's
  # own row" and "the other account's row" the same row. The suite's ordinary
  # authenticated account (`test/support/identity_helpers.rb`) is the right one, and
  # the fixtures below place one customer and one subscription there so that "A asks
  # for B" is a request that *could* have succeeded.
  CALLER = TestSupport::TestIdentity::Account

  # A third account, for the write test. `TwoAccounts` gives two and this needs one
  # that holds **no** customer, because `customers` is unique on
  # `(owner_type, owner_id, processor)` and a 409 would satisfy an assertion that
  # proved nothing about which owner was written.
  THIRD_ACCOUNT = "55555555-5555-4555-8555-555555555555".freeze

  class << self
    # The tests in this file, read at **run** time — the `test` macro defines each
    # method as the class body is evaluated, so a count taken while the body is
    # still executing would see only the tests above it.
    #
    # `public_instance_methods(false)` rather than `instance_methods`, so the
    # helpers `ActionDispatch::IntegrationTest` contributes are not counted.
    def negative_test_methods
      public_instance_methods(false).grep(/\Atest_/).reject { |method| method.to_s.start_with?("test_meta:") }.sort
    end
  end

  # A sentinel that exists only to be recognised. It is set on **account B's**
  # row, because the boundary tests read B's row: a 200 about B would prove the gap
  # by returning a value only B had. `assert_includes body, sentinel` would print the
  # body on failure — which on this surface is the other account's billing data — so
  # the assertion below uses `include?` directly and puts a sentence in the message.
  # The sentinel is a made-up address on the reserved `.invalid` TLD, so it is
  # recognisable as a fixture in any log it reaches.
  SENTINEL_EMAIL = "account-b-sentinel@example.invalid".freeze

  # The value the cross-account `PATCH` sends. **Different from the sentinel on
  # purpose**: writing a row the value it already holds is a no-op, and a no-op cannot
  # distinguish "the write reached the other account" from "the write reached nobody".
  # Two sentinels, so the assertion is about a change.
  REWRITTEN_EMAIL = "account-b-rewritten@example.invalid".freeze

  setup do
    travel_to(frozen_now)
    create_account_customers
    create_account_subscriptions
    customer_b.update!(email: SENTINEL_EMAIL)
    # The caller's own rows, so every test below is a request that *would* have been
    # answered had it named its own resource. Without them "B is refused" and "B
    # exists and is addressable" are indistinguishable from "the ids are nonsense".
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

  # --- absence, not refusal -------------------------------------------------

  # The property, on all three uuid-addressed resources, in one test each so a
  # failure names which resource started answering differently.
  #
  # **billing-21 added the fourth case and it is the one that matters**: another
  # account's row. `render_not_found` renders exactly one sentence with no branch for
  # *why* the identifier failed, so "does not exist", "cannot name one" and "belongs
  # to somebody else" are not merely three 404s — they are the same document, and the
  # only fields that differ are the ones that differ on every request: the trace id
  # and the path echoed in `instance`.
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

  # Plans are addressed by slug on the way in and by uuid on the way out, so the
  # slug path gets its own case: a handle nobody wrote has to be the same answer
  # as a handle that was never a uuid. The two lookups are deliberately different
  # and both are 404 for the other's identifier, which the routes file says and
  # this holds to.
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

  # A 404 carries the whole of what a 404 may carry, and nothing else.
  #
  # **The interesting field is `instance`**, which is the request path — so a 404
  # *does* repeat the identifier it refused. That is not an oracle, and the
  # distinction is worth making precisely: the identifier is the caller's own
  # input, echoed back to a caller who already has it, which discloses nothing.
  # An oracle would be the 404 saying anything the caller did not send — a price, a
  # plan, a status, an address, or *which of several reasons* it refused.
  #
  # So the property asserted here is that the body is the caller's input and a
  # fixed sentence, and carries nothing about any row. That is what makes a 404
  # safe to reuse for another account's row — which is exactly what billing-21
  # started doing — and it is the reason a 404 that grew a second `detail` for
  # "exists but not yours" would be the first thing to break.
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

  # --- the 403 audit --------------------------------------------------------

  # **Zero 403s, and it is structural rather than a survey.**
  #
  # The brief's rule is that a 403 on a resource the caller cannot see is an
  # enumeration oracle: it says "this exists, you may not have it", where a 404
  # says nothing. So the check is not "we did not write a 403 today" but "this
  # service has no way to emit one" — the problem vocabulary is a **frozen table**,
  # `Problem::CATALOG`, and a status outside it cannot be rendered at all.
  #
  # That makes the guarantee a property of a closed set rather than of a review,
  # which is why it is asserted against the whole table and not against a grep.
  # **401 joined the table in billing-21** (`unauthorized`), which is core's own
  # reserved code and is about the *caller*; 403 did not, and the list below is the
  # statement that it still has not.
  test "read: this service cannot emit a 403, so it cannot be an enumeration oracle" do
    statuses = Problem::CATALOG.values.map { |entry| Rack::Utils.status_code(entry.fetch(:status)) }

    refute_includes statuses, 403,
      "a 403 was added to the problem vocabulary. A 403 on a resource the caller cannot " \
      "see distinguishes it from one that does not exist, which is exactly the " \
      "enumeration oracle this service must not have. Use 404, or nil at the query."
    assert_equal statuses.uniq.sort, [ 400, 401, 404, 409, 422, 500, 503 ],
      "the problem vocabulary's statuses changed. 401 is `unauthorized`, added in billing-21 " \
      "for the token check, and is about the caller. This service answers 404 for absence, " \
      "never 403."
  end

  # **The 401 is a code this service added deliberately and it is in core's reserved
  # list**, so it is worth one assertion of its own: a reader checking the list above
  # sees `401` and needs to know which code produces it.
  test "read: the 401 is `unauthorized`, which is core's reserved code" do
    entry = Problem::CATALOG.fetch(:unauthorized)

    assert_equal :unauthorized, entry.fetch(:status)
    assert_equal 401, Rack::Utils.status_code(entry.fetch(:status))
    assert_operator Problem::CATALOG.keys, :include?, :unauthorized
  end

  # The same fact from the source side, so a `render_problem` reached with a raw
  # status — bypassing `CATALOG` — would be caught even though `CATALOG` did not
  # change. The two directions are asserted separately because a comparison that
  # stops at the first of them hides the second behind it.
  #
  # **Two changes, both deliberate.**
  #
  # `:unauthorized` is out of the pattern: it was there as a proxy for "a status this
  # service must not render", and billing-21 established that 401 is one it must — it
  # is the token check. What is banned, and what this still scans for, is a 403.
  #
  # **Comment lines are dropped before the scan**, and that makes the check stronger
  # rather than weaker. It used to match prose, so a file explaining *why* there is no
  # 403 was reported as an offender and the only way to write the explanation was to
  # not write it — which is how a rule ends up undocumented and therefore
  # unenforceable. Stripping `#` lines means the scan can only be satisfied by code, and
  # `app/controllers/concerns/authenticates_principal.rb` now carries three paragraphs
  # about 403s without tripping it.
  test "read: no controller renders a 403 by any route" do
    offenders = app_sources.select { |path, source|
      source.lines.reject { |line| line.strip.start_with?("#") }.any? { |line| line.match?(/\b403\b|forbidden/i) }
    }

    assert_empty offenders.keys,
      "these files write a 403 or `forbidden` in code. Absence is not refusal: a resource the " \
      "caller may not see must be indistinguishable from one that does not exist. Offenders: " \
      "#{offenders.keys.inspect}"
  end

  # The complement, so stripping comments is not a way to hide a 403: the scan
  # still reads every file, and a file that has grown a real 403 is reported whatever
  # else is in it.
  test "read: the 403 scan reads every file under app/ rather than a list" do
    assert_operator app_sources.size, :>=, 40,
      "the scan found far fewer files than app/ has. A scan over a short list is a scan over " \
      "a list somebody maintained."
  end

  # --- the boundary: another account's row is absent -------------------------

  # The rewrite of `gap: read — a customer is reachable by its uuid alone`. Same
  # request, opposite assertion, and the second half is the one that says *absent*
  # rather than *not found*: a 404 that merely named the id would still be an oracle,
  # so the response is compared against the missing-uuid case.
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

  # The rewrite of `gap: update — a customer is writable by its uuid alone`. The
  # `PATCH` names only account B's uuid, so the assertion is that B's row is
  # **byte-identical** afterwards — asserted with `drifted_ids` so a failure names
  # which row moved without printing another account's billing data.
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

  # The mutating direction is the expensive one, so both are exercised. A
  # cancellation is a request to the processor: the assertion that matters is that
  # the processor was **never asked**, because a cancel that got as far as Stripe and
  # was then refused would have moved money.
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

  # The rewrite of `gap: list — a subscription listing is not scoped to an account`.
  # The listing is scoped, and the assertion is that B's row is **absent** while the
  # caller's own row is present — one assertion rather than two, because a listing
  # that returned nothing at all would pass a weaker version of this.
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

  # A `User`-owned customer belongs to no account, so **no** account-scoped caller can
  # see it. That is the rule that makes `POST /v1/subscriptions`'s refusal of a
  # user-owned customer coherent rather than arbitrary: billing cannot know which
  # account a user belongs to, so a row like that has no tenant to be scoped to.
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

  # `POST /v1/customers` writes the caller's own account onto the row whatever the
  # body says. This is the write half of the boundary and the only place a body field
  # could have named somebody else's tenant.
  test "write: a customer created through /v1 is owned by the token's account, not by the body" do
    # A third account, holding no customer yet. Both A and B already hold one from
    # `TwoAccounts`, and `customers` is unique on `(owner_type, owner_id, processor)`,
    # so creating for either of them would be a 409 whatever the body said — and a test
    # that passed on a 409 would prove nothing about which owner was written.
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

  # --- meta: the counts this file claims -----------------------------------

  test "meta: this file holds 21 negative tests" do
    assert_equal 21, self.class.negative_test_methods.size
  end

  # The tripwire above only ever worked while the count was zero. It is now a
  # **positive** assertion, and that is the point: the gap this file recorded has
  # closed, and the count that used to detect it closing is asserted so a future
  # change that removed the scoping would be a failure here too.
  #
  # **The count is pinned, not asserted `> 0`, and the reason is a mutation this
  # assertion got wrong the first time.** `> 0` asks "is there any scoping left?"
  # and a refactor that deletes `Subscription.for_account` while leaving
  # `Customer.for_account` answers yes. Four of the twenty-one tests above are then
  # asserting a boundary the code no longer has, and this file is green. An exact
  # count fails on losing either one, which is the only version of the claim worth
  # making.
  #
  # It was `> 0` **and** a prefix-matching regex, so the first attempt did not
  # merely weaken the check — it could not be moved at all: `scope :for_account`
  # matches `scope :for_account_disabled` too, so renaming a scope to disable it
  # left the count untouched. The pattern is now word-anchored.
  test "meta: the account-constrained queries are exactly the three scopes and their callers" do
    assert_equal 6, account_scoped_queries,
      "the account-constrained queries in app/ are not the ones this file's tests are about. " \
      "`Subscription.for_account`, `Customer.for_account` or `Charge.for_account` has been " \
      "renamed or removed, which means the rewritten tests above are asserting a boundary the " \
      "code no longer has. Measured: 3 named scopes + 3 inline `where`/`find_by` constraints. " \
      "The checkout door's own scoping is a call to the named `Customer.for_account` scope, so " \
      "it is not one of these three — it is held by the file list below instead, where a call " \
      "that appears somewhere the boundary does not reach fails by name."
    # Comment lines are dropped before the scan, for the reason the 403 scan above
    # gives: a file explaining that it does *not* call `Customer.for_account` is
    # not an account-scoped entry point, and a scanner whose only remedy is
    # deleting the explanation is backwards.
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
    # The 404 body without the two fields that differ on every request: the trace
    # id and the path echoed in `instance`. Everything else must match exactly.
    def problem_without_request_echo
      json_body.except("trace_id", "instance")
    end

    # How many queries in `app/` constrain on an account. **Zero until billing-21**,
    # when the four characterisation tests above failed with their own instructions and
    # were rewritten as boundary tests. Still counted the same way, because the tripwire
    # is the property and the count is only how it is measured.
    #
    # Two shapes, because scoping can arrive in either: a `where`/`find_by` with
    # `account_id:` or `owner_id:` in it, or a named scope.
    #
    # **`\b` on the scope name is load-bearing.** Without it `scope :for_account`
    # also matches `scope :for_account_disabled`, so a refactor that renamed the
    # scope in order to turn it off would leave this count untouched and the
    # boundary tests above asserting a scope that no longer exists. This was not
    # hypothetical: that is the mutation that caught the `> 0` assertion above.
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
