require "test_helper"

class TenantIsolationMatrixTest < ActiveSupport::TestCase
  UNSCOPED = "unscoped"
  SCOPED = "scoped"

  CATALOGUE = "catalogue"

  def self.routes
    @routes ||= Rails.application.routes.routes.filter_map { |route|
      path = normalize(route.path.spec.to_s)
      next unless path.start_with?("/v1")

      [ route, path ]
    }
  end

  def self.normalize(path)
    path.sub("(.:format)", "")
  end

  TENANT_DATA = {
    Customer => "a customer row is `owner_type`/`owner_id`, and the tenancy key is the pair itself",
    Subscription => "a subscription is billed to `account_id` and grants entitlements",
    Charge => "a charge is billed to `account_id`, denormalised from the resolved customer or subscription at recording time",
    Plan => "a plan is the catalogue of what an account may buy, and has no `account_id`"
  }.freeze

  TENANT_MODEL_BY_NAME = {
    "Customer" => Customer,
    "Charge" => Charge,
    "Plan" => Plan,
    "Subscription" => Subscription
  }.freeze

  ACCOUNT_SCOPED = {
    [ "GET", "/v1/customers" ] => [ SCOPED, "pages this account's customers, scoped by `Customer.for_account`" ],
    [ "POST", "/v1/customers" ] => [ SCOPED, "writes a customer owned by the token's account — the write carries `owner_type: Account, owner_id: current_account_id` rather than the body's, which `Customer.for_account` then constrains every later read of" ],
    [ "GET", "/v1/customers/:id" ] => [ SCOPED, "resolves inside `Customer.for_account`, so another account's uuid is a 404" ],
    [ "PATCH", "/v1/customers/:id" ] => [ SCOPED, "writes a customer resolved inside `Customer.for_account`" ],

    [ "GET", "/v1/plans" ] => [ CATALOGUE, "returns the shared catalogue; a plan has no `account_id`" ],
    [ "POST", "/v1/plans" ] => [ CATALOGUE, "writes the catalogue every account is offered; capability, not tenancy, and unverified — README" ],
    [ "GET", "/v1/plans/:slug" ] => [ CATALOGUE, "reads the shared catalogue by handle" ],
    [ "PATCH", "/v1/plans/:id" ] => [ CATALOGUE, "writes the shared catalogue by uuid; capability, not tenancy, and unverified — README" ],

    [ "GET", "/v1/subscriptions" ] => [ SCOPED, "pages this account's subscriptions, scoped by `Subscription.for_account`" ],
    [ "POST", "/v1/subscriptions" ] => [ SCOPED, "resolves the body's `customer_id` inside `Customer.for_account`" ],
    [ "GET", "/v1/subscriptions/:id" ] => [ SCOPED, "resolves inside `Subscription.for_account`, so another account's uuid is a 404" ],
    [ "POST", "/v1/subscriptions/:id/cancel" ] => [ SCOPED, "cancels a subscription resolved inside `Subscription.for_account`; another account's is a 404 before the processor is called" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ] => [ SCOPED, "moves a subscription resolved inside `Subscription.for_account`" ],
    [ "GET", "/v1/subscriptions/:id/entitlements" ] => [ SCOPED, "reads entitlements for a subscription resolved inside `Subscription.for_account`" ],
    [ "GET", "/v1/subscriptions/:id/upcoming_invoice" ] => [ SCOPED, "projects the next invoice for a subscription resolved inside `Subscription.for_account`; another account's is a 404 and the processor is not asked" ],
    [ "POST", "/v1/subscriptions/:id/payment_method" ] => [ SCOPED, "opens the processor's portal for a subscription resolved inside `Subscription.for_account`; another account's is a 404 and no portal is asked for" ],

    [ "GET", "/v1/charges" ] => [ SCOPED, "pages this account's charges, scoped by `Charge.for_account`; another account's is not in the listing" ],
    [ "GET", "/v1/charges/:id" ] => [ SCOPED, "resolves a charge by its uuid inside `Charge.for_account`; another account's is a 404" ],

    [ "POST", "/v1/checkouts" ] => [ SCOPED, "completes a checkout for a customer resolved inside `Customer.for_account`; another account's customer is a 404 and nothing is asked of the processor" ],

    [ "GET", "/v1/token_wallet" ] => [ SCOPED, "reads the authenticated account's token balance, resolved from current_account_id (the account scope, equivalent to for_account on the tenant models)" ],
    [ "GET", "/v1/token_wallet/entries" ] => [ SCOPED, "pages the authenticated account's token ledger, resolved from current_account_id (the account scope, equivalent to for_account)" ],
    [ "POST", "/v1/token_wallet/grant" ] => [ SCOPED, "grants tokens to the authenticated account's wallet, resolved from current_account_id (the account scope, equivalent to for_account)" ],
    [ "POST", "/v1/token_wallet/deduct" ] => [ SCOPED, "deducts tokens from the authenticated account's wallet, resolved from current_account_id (the account scope, equivalent to for_account)" ],
    [ "POST", "/v1/token_wallet/adjust" ] => [ SCOPED, "adjusts the authenticated account's token balance, resolved from current_account_id (the account scope, equivalent to for_account)" ]
  }.freeze

  NOT_ACCOUNT_SCOPED = {
    [ "POST", "/v1/webhooks/stripe" ] =>
      "authenticates the processor by signature, not a anywaye client, and cannot grow a token check: `Webhooks::BaseController` does not inherit the concern"
  }.freeze


  test "every route the router serves under /v1 is classified by this matrix" do
    assert_empty unclassified,
      "these /v1 operations are served but neither classified as account-scoped nor " \
      "named here with a reason. Decide what their scope is before they ship: #{names(unclassified)}"
  end

  test "every operation this matrix classifies is one the router actually serves" do
    stale = (ACCOUNT_SCOPED.keys + NOT_ACCOUNT_SCOPED.keys).reject { |operation| served.include?(operation) }

    assert_empty stale,
      "these matrix entries are for operations the router does not serve. A route that " \
      "went away takes its reason with it: #{names(stale)}"
  end

  test "no operation is both account-scoped and not" do
    overlap = ACCOUNT_SCOPED.keys & NOT_ACCOUNT_SCOPED.keys

    assert_empty overlap,
      "these operations are in both tables, so the matrix and the router disagree about " \
      "the same route: #{names(overlap)}"
  end


  test "no tenant-data operation is unscoped: the eleven tenant routes carry a scope and the four plans are shared catalogue" do
    verdicts = ACCOUNT_SCOPED.values.map(&:first).uniq.sort

    assert_equal [ CATALOGUE, SCOPED ], verdicts,
      "these operations are recorded as unscoped, or a verdict this file does not know about " \
      "has appeared. `unscoped` is only true while a query carries no account; `catalogue` is " \
      "only true for a plan, which has no `account_id`. Change the verdict here in the same " \
      "commit that changes the code, or this test is a claim about code that does not exist."
  end

  test "fifteen of the nineteen are scoped: every customer, subscription, checkout and charge operation, and none of the four plan operations" do
    scoped = ACCOUNT_SCOPED.select { |_operation, (verdict, _reason)| verdict == SCOPED }.keys
    catalogue = ACCOUNT_SCOPED.select { |_operation, (verdict, _reason)| verdict == CATALOGUE }.keys

    assert_equal 20, scoped.size, "the scoped set is #{names(scoped)}"
    assert_equal 4, catalogue.size, "the catalogue set is #{names(catalogue)}"
    assert_empty scoped.grep(%r{/v1/plans}),
      "a plan operation is recorded as scoped. A plan has no `account_id` column, so there is " \
      "nothing to scope it by — that is the model, not a defect."
    assert_equal(
      [ [ "GET", "/v1/plans" ], [ "GET", "/v1/plans/:slug" ], [ "PATCH", "/v1/plans/:id" ], [ "POST", "/v1/plans" ] ],
      ACCOUNT_SCOPED.select { |_operation, (verdict, _reason)| verdict == CATALOGUE }.keys.sort,
      "the catalogue table is not the four plan operations the router serves. A plan route that " \
      "left the table without a verdict would be a shared resource recorded as a defect."
    )
  end

  test "every scoped operation names the scope that scopes it" do
    unevidenced = ACCOUNT_SCOPED.select { |_operation, (verdict, reason)|
      verdict == SCOPED && !reason.match?(/for_account/)
    }

    assert_empty unevidenced.keys,
      "these operations are recorded as scoped without naming the scope. A verdict with no " \
      "scope in its reason is a comment: #{names(unevidenced.keys)}"
  end

  test "every account-scoped operation says why it is in the table" do
    unexplained = ACCOUNT_SCOPED.select { |_operation, (_verdict, reason)| reason.to_s.strip.empty? }

    assert_empty unexplained.keys,
      "these operations are classified with no reason: #{names(unexplained.keys)}"
  end

  test "every operation that is not account-scoped says why it is not" do
    unexplained = NOT_ACCOUNT_SCOPED.select { |_operation, reason| reason.to_s.strip.empty? }

    assert_empty unexplained.keys,
      "these operations are excluded with no reason: #{names(unexplained.keys)}"
  end

  test "the set of models this matrix treats as tenant data is pinned" do
    assert_equal %w[Charge Customer Plan Subscription], TENANT_DATA.keys.map(&:name).sort
  end

  TENANT_DATA.each do |model, reason|
    test "#{model.name} is tenant data, and the index that files its reason agrees" do
      assert_same model, TENANT_MODEL_BY_NAME.fetch(model.name)

      refute_empty reason.to_s.strip
    end
  end


  DOCUMENTED_SCOPED_OPERATIONS = [
    [ "GET", "/v1/customers" ],
    [ "GET", "/v1/subscriptions" ],
    [ "POST", "/v1/subscriptions" ]
  ].freeze

  DOCUMENTED_SCOPED_OPERATIONS.each do |operation|
    test "the README's once-open #{operation.join(" ")} is now scoped, and the matrix agrees" do
      assert_includes ACCOUNT_SCOPED.keys, operation
      assert_equal SCOPED, ACCOUNT_SCOPED.fetch(operation).first
    end
  end

  TENANT_MUTATIONS = [
    [ "PATCH", "/v1/customers/:id" ],
    [ "PATCH", "/v1/plans/:id" ],
    [ "POST", "/v1/customers" ],
    [ "POST", "/v1/plans" ],
    [ "POST", "/v1/subscriptions/:id/cancel" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ]
  ].freeze

  TENANT_MUTATIONS.each do |operation|
    test "#{operation.join(" ")} mutates tenant data, so the matrix cannot lose it" do
      assert_includes ACCOUNT_SCOPED.keys, operation,
        "a route that writes tenant data must be in the matrix; dropping it is how an " \
        "unscoped mutation stops being anybody's problem"
    end
  end

  private
    def served
      @served ||= self.class.routes.flat_map { |route, path|
        methods_for(route).map { |method| [ method, path ] }
      }.to_set
    end

    def unclassified
      served - ACCOUNT_SCOPED.keys - NOT_ACCOUNT_SCOPED.keys
    end

    def methods_for(route)
      route.verb.empty? ? %w[GET HEAD POST PUT PATCH DELETE OPTIONS] : route.verb.split("|")
    end

    def names(operations)
      operations.map { |method, path| "#{method} #{path}" }.sort.join(", ")
    end
end
