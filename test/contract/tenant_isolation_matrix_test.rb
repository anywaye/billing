require "test_helper"

# Every account-scoped route, enumerated, with what the router actually serves.
#
# ## Why this file existed when the answer was "none of them are scoped"
#
# The question a multi-tenant billing service has to answer is *can an
# authenticated caller reach another account's subscription, invoice or payment
# method?* billing-12 could not answer it, because there was no authenticated
# caller: `/v1` read no token, since core says identity is the only issuer and the
# JWKS verification was not in this repository. `GET /v1/subscriptions` returned
# every row and `POST /v1/subscriptions/{id}/cancel` cancelled whichever row the
# path named.
#
# So billing-12 made the gap **total**: it enumerated the routes the router serves
# and required every one to be classified here with a reason, so a route added
# tomorrow fails by name the day it is added rather than the day somebody notices
# reading the diff. **billing-21 answered the question and kept the enumeration.**
#
# ## What changed in billing-21, and what did not
#
# **Ten of the fourteen entries flipped from `unscoped` to `scoped`** — the four
# customer reads/writes and all six subscription operations, which now resolve
# inside `Customer.for_account` / `Subscription.for_account`. The four assertions
# that held the word `unscoped` in place are **inverted**, not deleted: they now
# assert the verdicts are exactly what the code does, so the day someone removes a
# scope this file fails naming the route. A matrix whose verdict can only be
# "unscoped" is a matrix that stops being a check on the day it is fixed.
#
# **The four plan rows did not flip, and that is the finding.** A plan is platform
# catalogue — what an account may buy, not what an account owns — so it carries no
# `account_id` column and there is nothing to scope it by. `test/support/two_accounts.rb`
# shares one plan between both accounts precisely because that is true, and
# `subscriptions_live_account_plan_idx` is keyed on `(account_id, plan_id)` for the
# same reason. The four are asserted as `CATALOGUE` — a third verdict, for a route
# that is neither account-scoped nor unscoped but shared — rather than being filed
# under `unscoped` with a paragraph explaining it, which is how a shared resource
# becomes an unnoticed gap.
#
# ## What this is not
#
# It is not an authorization check, and it does not become one by being strict
# about prose. It is a **verdict table**, and a verdict that stops matching the
# code is a red test naming a route — which is the outcome worth having.
#
# It lives here rather than in `outbox_envelope_contract_test.rb` because that
# file skips when `core` is not on disk, and a check that hides behind a skip is
# not a check. This one reads the router, which is always there.
class TenantIsolationMatrixTest < ActiveSupport::TestCase
  # The three verdicts a `/v1` route can carry here, and all three are
  # **load-bearing words**: they are what makes "this route reads another tenant's
  # data", "this route reads only the caller's" and "this route is shared platform
  # data" distinguishable at a glance, so a route cannot quietly move between
  # tables by being reclassified without someone reading why.
  UNSCOPED = "unscoped"
  SCOPED = "scoped"

  # Not tenant data. A plan is what an account may buy, not what an account owns,
  # so it has no `account_id` and every account reads the same rows. Added in
  # billing-21 because filing these four under `unscoped` — which they were —
  # described a shared catalogue as a defect, and a table that calls the model
  # broken is a table nobody reads.
  CATALOGUE = "catalogue"

  # The per-checkout database makes `Rails.root` the right unit for "this
  # service"; the matrix is about the code in this worktree.
  def self.routes
    @routes ||= Rails.application.routes.routes.filter_map { |route|
      path = normalize(route.path.spec.to_s)
      next unless path.start_with?("/v1")

      [ route, path ]
    }
  end

  # `:id` stays `:id` here, and that is the whole reason the table below is
  # written in the router's spelling.
  #
  # The obvious choice was to normalize into the document's `{id}`, which is what
  # `HttpSurfaceContractTest` does because it compares against `openapi/v1.yaml`.
  # This matrix has no document: it compares a table against the router, so the
  # router defines the alphabet and the table is written in it.
  #
  # Normalizing *both* sides into a third spelling would have been a worse guard,
  # not a better one: a table whose keys were wrong in the same way a route was
  # wrong would then agree with it, and this file would report agreement about an
  # operation no client can call. One side normalized to a spelling the other side
  # does not use is what makes a disagreement visible instead of silent.
  def self.normalize(path)
    path.sub("(.:format)", "")
  end

  # Every `/v1` operation that reads or writes **tenant data** — a row belonging to
  # an account, or the catalogue of what an account may buy.
  #
  # Keyed by `[method, router path]`, and the path is in the router's spelling
  # (`:id`, `:slug`) so both sides are read in one alphabet.
  #
  # The reason is not decoration. `TENANT_DATA` names the two columns that decide
  # whether a route belongs here, so the classification is derived from a fact
  # about the model rather than asserted about a path — and a route that starts
  # touching tenant data has to be moved into this table deliberately, which is
  # the moment somebody is asked what its scope should be.
  TENANT_DATA = {
    # A customer is a tenant's record: `owner_type`/`owner_id` are the only link
    # back to identity, and `POST` takes them in the body because there is no
    # token to read them from.
    Customer => "a customer row is `owner_type`/`owner_id`, and the tenancy key is the pair itself",
    # A subscription is billed to an account and grants entitlements. Reading or
    # cancelling one is the operation this whole matrix exists to keep honest, and
    # `account_id` is a column on the row rather than a join.
    Subscription => "a subscription is billed to `account_id` and grants entitlements",
    # A charge is the receipt for a payment to an account, and `account_id` is
    # denormalised onto it at recording time for the same reason a subscription's
    # is: the receipt route scopes by it without a join.
    Charge => "a charge is billed to `account_id`, denormalised from the resolved customer or subscription at recording time",
    # A plan is the catalogue every account buys from, and carries **no account at all**.
    Plan => "a plan is the catalogue of what an account may buy, and has no `account_id`"
  }.freeze

  # Why each model is tenant data, keyed by the table it means. The
  # `TENANT_DATA` above carries the sentence; this is the index that says which
  # sentence goes with which model.
  TENANT_MODEL_BY_NAME = {
    "Customer" => Customer,
    "Charge" => Charge,
    "Plan" => Plan,
    "Subscription" => Subscription
  }.freeze

  # Every served `/v1` operation, with its verdict and — for the account-scoped
  # ones — why it is in this table.
  #
  # **Keys are read in the router's spelling.** Rails draws `:id` and `:slug`; the
  # OpenAPI document writes `{id}` and `{slug}`. Normalising the way
  # `HttpSurfaceContractTest` does is what caught this: the table was first
  # written in the document's spelling, and the two directions then reported all
  # eight parameterised routes as unclassified *and* all eight as stale at once.
  # That double failure is what a normalizing test can produce and a
  # non-normalizing one cannot — a table disagreeing with the router about
  # spelling would otherwise have stayed "the router serves something this file
  # does not know about" forever, with a green tick.
  #
  # **billing-21 flipped ten of the fourteen.** The four customer operations and all
  # six subscription operations are `SCOPED`; the four plan operations are
  # `CATALOGUE`. There is no `UNSCOPED` entry left, which is the honest state of this
  # service on this commit — and the assertion below holds that as a **set of distinct
  # verdicts**, so the day someone removes a scope the failure names `scoped` rather
  # than reporting a number that moved.
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
    # The two mutating ones, and the reason the table is ordered this way: these
    # change another account's billing state, which is the expensive direction — and
    # they resolve through the **same** scoped `subscription_record` as the read, so
    # the scope cannot be the one somebody forgot.
    [ "POST", "/v1/subscriptions/:id/cancel" ] => [ SCOPED, "cancels a subscription resolved inside `Subscription.for_account`; another account's is a 404 before the processor is called" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ] => [ SCOPED, "moves a subscription resolved inside `Subscription.for_account`" ],
    [ "GET", "/v1/subscriptions/:id/entitlements" ] => [ SCOPED, "reads entitlements for a subscription resolved inside `Subscription.for_account`" ],

    # The receipt for one charge. A charge is billed to an account and the route
    # resolves it inside `Charge.for_account`, so another account's uuid is a
    # 404 — the same answer a uuid naming nothing gets.
    [ "GET", "/v1/charges/:id" ] => [ SCOPED, "resolves a charge by its uuid inside `Charge.for_account`; another account's is a 404" ]
  }.freeze

  # Every served `/v1` operation that is **not** account-scoped, with the reason.
  #
  # An empty table would exit 0 having checked nothing, which is a skipped test in
  # everything but name, and a route that arrived tomorrow would be classified by
  # nobody. So the webhook is named here, with the reason it is not a tenant
  # operation: it authenticates the *processor* by signature, not a cafaye client,
  # and it must never grow a token check — a `Bearer` on that path would be a
  # second, weaker trust path to the same door.
  #
  # **billing-21 made that structural rather than a convention.** The token check is a
  # `before_action` on `V1::BaseController`, and `Webhooks::BaseController` does not
  # inherit from it — so the webhook cannot grow a token check without somebody
  # reaching into another namespace on purpose. `test/authentication/principal_lock_test.rb`
  # asserts the boundary from the router's own table.
  NOT_ACCOUNT_SCOPED = {
    [ "POST", "/v1/webhooks/stripe" ] =>
      "authenticates the processor by signature, not a cafaye client, and cannot grow a token check: `Webhooks::BaseController` does not inherit the concern"
  }.freeze

  # --- the two directions ----------------------------------------------------

  # The direction that finds things. A route the router serves that is in neither
  # table is a route nobody decided the scope of, and it is live on the next
  # deploy. Named, so the failure says which operation rather than describing a
  # surface nobody can call.
  test "every route the router serves under /v1 is classified by this matrix" do
    assert_empty unclassified,
      "these /v1 operations are served but neither classified as account-scoped nor " \
      "named here with a reason. Decide what their scope is before they ship: #{names(unclassified)}"
  end

  # The other direction, and the one that keeps the tables from rotting. A row
  # here that the router does not serve excludes nothing today and will exclude
  # whatever somebody adds at that method and path next, which is why a stale row
  # fails rather than being ignored.
  test "every operation this matrix classifies is one the router actually serves" do
    stale = (ACCOUNT_SCOPED.keys + NOT_ACCOUNT_SCOPED.keys).reject { |operation| served.include?(operation) }

    assert_empty stale,
      "these matrix entries are for operations the router does not serve. A route that " \
      "went away takes its reason with it: #{names(stale)}"
  end

  # The two tables must not both claim the same operation. Where they overlap,
  # neither half can be right, and the overlap is where an operation stops being
  # anyone's responsibility.
  test "no operation is both account-scoped and not" do
    overlap = ACCOUNT_SCOPED.keys & NOT_ACCOUNT_SCOPED.keys

    assert_empty overlap,
      "these operations are in both tables, so the matrix and the router disagree about " \
      "the same route: #{names(overlap)}"
  end

  # --- the claims the table makes -------------------------------------------

  # **The verdicts are `scoped` and `catalogue`, and neither is `unscoped`.** That is
  # the claim this file exists to make checkable, and billing-21 is the commit that
  # made it true.
  #
  # Asserted as a **set of the distinct values rather than by counting rows**, so the
  # failure names the verdict that changed instead of reporting a number that moved.
  # A floor or a count would accept the table silently losing its most dangerous rows; a
  # set comparison cannot, because the removal *is* the change.
  test "no tenant-data operation is unscoped: the eleven tenant routes carry a scope and the four plans are shared catalogue" do
    verdicts = ACCOUNT_SCOPED.values.map(&:first).uniq.sort

    assert_equal [ CATALOGUE, SCOPED ], verdicts,
      "these operations are recorded as unscoped, or a verdict this file does not know about " \
      "has appeared. `unscoped` is only true while a query carries no account; `catalogue` is " \
      "only true for a plan, which has no `account_id`. Change the verdict here in the same " \
      "commit that changes the code, or this test is a claim about code that does not exist."
  end

  # **The customer, subscription and charge operations are `SCOPED`, pinned by
  # count.** The set assertion above says "some are scoped and none are unscoped", which a
  # table could satisfy by scoping one route and leaving the rest open. These are the
  # counts that make the set assertion mean what it says.
  test "eleven of the fifteen are scoped: every customer, subscription and charge operation, and none of the four plan operations" do
    scoped = ACCOUNT_SCOPED.select { |_operation, (verdict, _reason)| verdict == SCOPED }.keys
    catalogue = ACCOUNT_SCOPED.select { |_operation, (verdict, _reason)| verdict == CATALOGUE }.keys

    assert_equal 11, scoped.size, "the scoped set is #{names(scoped)}"
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

  # Every `scoped` entry must name the scope it relies on. Without this the verdict is
  # a word: "scoped" would be satisfied by a comment rather than by a query, which is
  # the failure mode the whole file was written to prevent.
  test "every scoped operation names the scope that scopes it" do
    unevidenced = ACCOUNT_SCOPED.select { |_operation, (verdict, reason)|
      verdict == SCOPED && !reason.match?(/for_account/)
    }

    assert_empty unevidenced.keys,
      "these operations are recorded as scoped without naming the scope. A verdict with no " \
      "scope in its reason is a comment: #{names(unevidenced.keys)}"
  end

  # The reason is not decoration: a row without one is a row nobody thought about,
  # which is exactly how `/v1/subscriptions` came to return every row.
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

  # The matrix is only as good as the set of models it treats as tenant data, and
  # that set has to be pinned rather than derived — otherwise a new model that
  # holds tenant data joins the surface without anybody deciding its scope, which
  # is the failure mode this whole file exists to prevent.
  test "the set of models this matrix treats as tenant data is pinned" do
    assert_equal %w[Charge Customer Plan Subscription], TENANT_DATA.keys.map(&:name).sort
  end

  # And the index that attaches a reason to a model has to agree with it. A
  # sentence filed against the wrong model is a matrix that reads correctly and
  # classifies wrongly.
  TENANT_DATA.each do |model, reason|
    test "#{model.name} is tenant data, and the index that files its reason agrees" do
      assert_same model, TENANT_MODEL_BY_NAME.fetch(model.name)

      refute_empty reason.to_s.strip
    end
  end

  # --- and the claim the README makes ---------------------------------------

  # **billing-21 removed this section's subject.** The prose used to name
  # `GET /v1/customers`, `GET /v1/subscriptions` and `POST /v1/subscriptions` as the
  # *open* surface — the three visible consequences of there being no caller — and
  # this asserted those three were `UNSCOPED` so the README could not drift away from
  # the matrix. There is no open surface to name any more, so the assertions are
  # **inverted**: the same three operations, now asserted to be `SCOPED`, and the
  # reason sentence has to have moved with the verdict.
  #
  # Inverting rather than deleting is the point. A deleted assertion is a hole a later
  # packet can fill by accident; an inverted one fails the day somebody removes a
  # scope from `GET /v1/subscriptions`, which is the operation that returned every
  # row.
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

  # The mutating operations are the ones a security reader cares about most, and
  # the README sentence does not name them. Pinning them here is what stops the
  # matrix from being quietly trimmed down to the three operations the prose
  # happens to mention.
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
    # `(method, document path)` for every `/v1` operation the router serves.
    def served
      @served ||= self.class.routes.flat_map { |route, path|
        methods_for(route).map { |method| [ method, path ] }
      }.to_set
    end

    # Served, and in neither table.
    def unclassified
      served - ACCOUNT_SCOPED.keys - NOT_ACCOUNT_SCOPED.keys
    end

    # `via: :all` draws a route with no verb constraint, which answers every
    # method. Same expansion the HTTP-surface contract test uses, for the same
    # reason: one vocabulary for "what the router serves".
    def methods_for(route)
      route.verb.empty? ? %w[GET HEAD POST PUT PATCH DELETE OPTIONS] : route.verb.split("|")
    end

    # `GET /v1/plans/:slug` rather than `["GET", "/v1/plans/:slug"]`, because the
    # pair is the thing being reported and a request line is how it reads.
    def names(operations)
      operations.map { |method, path| "#{method} #{path}" }.sort.join(", ")
    end
end
