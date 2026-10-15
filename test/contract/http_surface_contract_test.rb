require "test_helper"

# The HTTP contract and the router, held to each other by method *and* path.
#
# `openapi/v1.yaml` is what a client is generated from and `config/routes.rb` is
# what answers. Two ways they can disagree, and neither is a small one for a
# service that handles money: an operation the document declares and the service
# does not serve is a call a generated client makes against a 404, and an
# operation the service serves and no document declares is reachable by nobody
# who wrote a client — an endpoint nobody chose, described nowhere.
#
# The check this replaces compared **paths only**, so it could not see this:
#
#     resources :customers, only: %i[index create show update]
#
# draws `PATCH /v1/customers/:id` and `PUT /v1/customers/:id`, and only the first
# was in the document. One path on each side, and the comparison reported
# agreement. Keying on `(method, path)` is what sees it.
#
# It lives here rather than in `test/contract/outbox_envelope_contract_test.rb`
# because that spec skips when `core` is not on disk, and a check that hides
# behind a skip is not a check. This one reads three files this repository owns —
# the document, the manifest and the route set — so it runs wherever the suite
# runs, with or without `core` beside it.
class HttpSurfaceContractTest < ActiveSupport::TestCase
  DOCUMENT = "openapi/v1.yaml"
  MANIFEST = "cafaye.yml"

  # --- what "served" means, and what is deliberately not served ----------------

  # The methods a route drawn `match …, via: :all` answers. The router draws
  # such a route with **no verb constraint at all** — `route.verb` is the empty
  # string, and an empty verb matches any request method — so an exclusion for
  # one is keyed under each of these rather than under a verb that is not a
  # method. A single entry keyed by "" would also "exclude" a route answering
  # GET alone, and would go stale the day a `via:` was narrowed. The test below
  # checks that claim against the router rather than trusting it.
  EVERY_METHOD = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

  # One entry per method for a route that answers all of them.
  def self.every_method(path, reason)
    EVERY_METHOD.to_h { |method| [ [ method, path ], reason ] }
  end

  HEALTH_PROBE = "Infrastructure, not contract surface: not in `cafaye.yml`'s " \
    "`exposes`, no query parameters, no auth, and an uptime monitor is the only " \
    "reader. `config/routes.rb` says so beside the declaration."

  RAILS_HEALTH = "Rails' built-in health route, kept by the framework rather than " \
    "drawn by hand in `config/routes.rb`, and infrastructure for the same reason."

  EXCEPTION_PAGE = "`config.exceptions_app` targets, declared at the bottom of " \
    "`config/routes.rb`. Not a client operation: this is where the app **lands** " \
    "when Rails raised rather than one a controller rendered, so a 404 on an " \
    "unknown path and a 500 on an unhandled bug are problem+json too. Drawn " \
    "`via: :all`, so every method."

  ACTION_CABLE = "ActionCable's mount, drawn by the railtie rather than by " \
    "`config/routes.rb`. A WebSocket endpoint, not an HTTP operation."

  ENGINE_ROUTES = "Drawn by a Rails engine that is loaded into the bundle, not by " \
    "`config/routes.rb`. This service has no ActionMailbox and no Active Storage " \
    "table in `db/schema.rb` and uses neither, so none of these is a cafaye " \
    "operation and none is described here. They are listed rather than filtered by " \
    "prefix because a route that appears without somebody adding it and writing " \
    "down why is the failure this file exists to catch."

  # Every `(method, path)` the router serves that is not a client operation, with
  # the reason it is not one: the two probes and Rails' own health route, the four
  # `exceptions_app` targets, the ActionCable mount, and the routes Rails engines
  # contribute.
  #
  # There is no prefix filter and no "anything under /v1 is contract surface"
  # shortcut, because a prefix cannot see a method: `start_with?("/v1")` is what
  # let `PUT /v1/customers/{id}` through a check that read paths only. A route is
  # named here with its reason, or it is in the document, and the test below
  # fails on anything that is neither.
  #
  # Keys are written in the **document's** spelling, so a Rails `:id` is `{id}`
  # here — that is the alphabet both sides of the comparison are read in.
  NOT_A_CLIENT_OPERATION = {
    [ "GET", "/healthz" ] => HEALTH_PROBE,
    [ "GET", "/readyz" ] => HEALTH_PROBE,
    [ "GET", "/up" ] => RAILS_HEALTH
  }.merge(
    every_method("/404", EXCEPTION_PAGE),
    every_method("/422", EXCEPTION_PAGE),
    every_method("/500", EXCEPTION_PAGE),
    every_method("/503", EXCEPTION_PAGE),

    every_method("/cable", ACTION_CABLE),

    {
      [ "POST", "/rails/action_mailbox/mandrill/inbound_emails" ] => ENGINE_ROUTES,
      [ "GET", "/rails/action_mailbox/mandrill/inbound_emails" ] => ENGINE_ROUTES,
      [ "POST", "/rails/action_mailbox/mailgun/inbound_emails/mime" ] => ENGINE_ROUTES,
      [ "POST", "/rails/action_mailbox/postmark/inbound_emails" ] => ENGINE_ROUTES,
      [ "POST", "/rails/action_mailbox/relay/inbound_emails" ] => ENGINE_ROUTES,
      [ "POST", "/rails/action_mailbox/sendgrid/inbound_emails" ] => ENGINE_ROUTES,

      [ "GET", "/rails/conductor/action_mailbox/inbound_emails" ] => ENGINE_ROUTES,
      [ "POST", "/rails/conductor/action_mailbox/inbound_emails" ] => ENGINE_ROUTES,
      [ "GET", "/rails/conductor/action_mailbox/inbound_emails/new" ] => ENGINE_ROUTES,
      [ "GET", "/rails/conductor/action_mailbox/inbound_emails/sources/new" ] => ENGINE_ROUTES,
      [ "GET", "/rails/conductor/action_mailbox/inbound_emails/{id}" ] => ENGINE_ROUTES,
      [ "POST", "/rails/conductor/action_mailbox/inbound_emails/sources" ] => ENGINE_ROUTES,
      [ "POST", "/rails/conductor/action_mailbox/{inbound_email_id}/reroute" ] => ENGINE_ROUTES,
      [ "POST", "/rails/conductor/action_mailbox/{inbound_email_id}/incinerate" ] => ENGINE_ROUTES,

      [ "GET", "/rails/active_storage/blobs/{signed_id}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/blobs/proxy/{signed_id}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/blobs/redirect/{signed_id}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/representations/{signed_blob_id}/{variation_key}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/representations/proxy/{signed_blob_id}/{variation_key}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/representations/redirect/{signed_blob_id}/{variation_key}/*filename" ] => ENGINE_ROUTES,
      [ "GET", "/rails/active_storage/disk/{encoded_key}/*filename" ] => ENGINE_ROUTES,
      [ "PUT", "/rails/active_storage/disk/{encoded_token}" ] => ENGINE_ROUTES,
      [ "POST", "/rails/active_storage/direct_uploads" ] => ENGINE_ROUTES
    }
  ).freeze

  # --- the keys this test is allowed to read in a path item ---------------------

  # The Path Item Object keys that name an operation, per OpenAPI 3.1.
  OPERATION_KEYS = %w[get put post delete options head patch trace].freeze

  # The Path Item Object keys that do not, and that therefore must not be read as
  # operations. `parameters` is the one that bites: every path item in this
  # document carries one, and a check that did not know the difference would
  # report `parameters` as an operation with no operationId.
  NOT_OPERATION_KEYS = %w[$ref summary description servers parameters].freeze

  # --- the operationIds a generator turns into method names --------------------

  # The fifteen names an SDK generated from this document exposes. Pinned rather
  # than derived: a generator reads these and nothing else, so a rename here is
  # not a refactor, it is a compile error in a customer's language, discovered by
  # them and not by us. The count is not asserted — the list is, so a removal and
  # an addition both fail and neither is mistaken for the other.
  OPERATION_IDS = %w[
    cancelSubscription
    changeSubscriptionPlan
    createCheckout
    createCustomer
    createPlan
    createSubscriptionCheckout
    getCharge
    getCustomer
    getPlan
    getSubscription
    getSubscriptionEntitlements
    listCustomers
    listPlans
    listSubscriptions
    receiveStripeWebhook
    updateCustomer
    updatePlan
  ].freeze

  test "every operation the document declares is served, and every operation served is declared" do
    # One assertion over the whole symmetric difference, and not one assertion
    # per direction: a test that stops at the first failure hides the second
    # direction behind it, and the second direction is the one that found the
    # `PUT`. Every disagreement is reported, by direction and by name.
    breaches = []
    breaches << "declared by the document but not served, so a client generated from it would " \
      "call a 404: #{names(declared_and_unserved)}" if declared_and_unserved.any?
    breaches << "served by the router but neither declared nor named on the exclusion list with " \
      "a reason: #{names(served_and_unexplained)}" if served_and_unexplained.any?

    assert_empty breaches, breaches.join(" — ")
  end

  # The other half of what keeps the list above from rotting: an exclusion that
  # has stopped matching anything is a hole waiting for a route, and an operation
  # that is both declared and excluded is a contradiction where neither half can
  # be right.
  test "every exclusion names a route the router serves, and excludes nothing the document declares" do
    assert_empty stale_exclusions,
      "these exclusions are for routes the router does not serve: #{names(stale_exclusions)}. " \
      "A route that went away takes its reason with it"

    assert_empty NOT_A_CLIENT_OPERATION.keys & documented.keys,
      "these operations are both declared and excluded, so the document and the exclusion " \
      "list disagree about the same route: #{names(NOT_A_CLIENT_OPERATION.keys & documented.keys)}"
  end

  test "every declared operation has an operationId, and no operationId is used twice" do
    assert_empty unnamed_operations,
      "these operations have no operationId, which is what a generator turns into a method " \
      "name: #{names(unnamed_operations)}"

    repeated = operation_ids.tally.select { |_id, count| count > 1 }.keys.sort

    assert_empty repeated,
      "these operationIds are used by more than one operation, and a generator would emit " \
      "two methods with one name: #{repeated.inspect}"
  end

  test "the operationIds are the ones a generated SDK names" do
    assert_equal OPERATION_IDS, operation_ids.sort
  end

  # `EVERY_METHOD` above is a claim about what `via: :all` means, and the
  # exclusion list above is written as though the claim holds. This reads it back
  # out of the router: for every route drawn with no verb constraint, the methods
  # the exclusions are keyed by are exactly the ones the router answers. Narrow a
  # `via:` and this goes red, rather than the list quietly covering a route that
  # stopped answering POST.
  test "a route drawn via: :all answers every method its exclusions are keyed by" do
    unconstrained = unconstrained_routes

    assert_not_empty unconstrained,
      "no route is drawn `via: :all` any more: re-read EVERY_METHOD and the exclusions keyed by it"

    unconstrained.each do |route|
      served_by = methods_for(route)
      recognized = EVERY_METHOD.select { |method| recognizes?(route, method) }

      assert_equal served_by, recognized,
        "#{route.path.spec} is excluded under #{served_by.inspect} but the router only answers " \
        "#{recognized.inspect} for it: narrow the exclusion, or widen it to what is served"
    end
  end

  test "the document's version moved, because the document did" do
    # core's sync rule: a non-breaking addition bumps only `info.version`, never the
    # `/v1` prefix. Asserted so a future packet that adds an endpoint and forgets to
    # bump the document's own version is caught here rather than by a reader.
    #
    # It is a pin and not a derived value on purpose. A test that read the version
    # out of the document and compared it with itself would pass every document ever
    # written, including a regenerated one.
    #
    # **2.0.0 (billing-21) is a major bump under an unchanged `/v1` prefix**, which
    # core's rule says should not happen — so the reasoning is in the document's own
    # header and the assertion here is deliberately only the version. Keeping `/v1`
    # while the surface breaks is a judgement call, not an oversight: the old prefix
    # answers every request without a token, so "keep serving `/v1`" would be "keep the
    # vulnerability". See the header on `info.version` and README's "Breaking change".
    #
    # **2.1.0 is the receipts packet**: one additive operation,
    # `GET /v1/charges/{id}`, and nothing else moved. A non-breaking addition bumps
    # only `info.version` — the `/v1` prefix is untouched, and the bump is what a
    # client generator reads.
    #
    # **2.2.0 is the checkout door**: one additive operation, `POST
    # /v1/checkouts`, over the fake processor that replaced `pay`'s
    # `FakeProcessor`. Nothing else moved, so it is a minor bump under the
    # unchanged prefix. The operation's own 404-when-disabled is in the
    # document's path description, and the request spec asserts it against the
    # controller — a document that promised an answer the router does not give is
    # the drift this whole file exists to catch.
    assert_equal "2.2.0", document.fetch("info").fetch("version")
  end

  # --- the security the document declares, and what the router actually does ----

  # `security: []` at the document level said this surface was open, and it was, and a
  # self-hoster reading this file had no way to tell that from an oversight. billing-21
  # replaced it with the real scheme, and these four assertions are what keeps it real:
  #
  #   1. the document declares a bearer scheme and applies it by default;
  #   2. **every** `/v1` operation except the webhook declares no override;
  #   3. the webhook declares `security: []` and says why;
  #   4. every `/v1` operation declares the two refusals the service can now answer.
  #
  # (4) is the one that catches the interesting edit. A new operation that a packet
  # added without thinking about authentication would still inherit `bearerToken`, so
  # the document would not lie — but it would not say what it answers when the token is
  # missing either, and a client generated from it would have no 401 to handle.
  DOCUMENT_ROOT_SECURITY = [ { "bearerToken" => [] } ].freeze

  UNAUTHENTICATED_OPERATION = "receiveStripeWebhook"

  test "the document declares a bearer scheme and applies it to every operation" do
    assert_equal DOCUMENT_ROOT_SECURITY, document["security"],
      "the document-level `security` changed. Every `/v1` operation inherits it, so this is " \
      "the single line that decides whether the whole surface is authenticated."

    assert_equal %w[bearerToken], document.dig("components", "securitySchemes").keys

    scheme = document.dig("components", "securitySchemes", "bearerToken")
    assert_equal "http", scheme["type"]
    assert_equal "bearer", scheme["scheme"]
  end

  test "every /v1 operation declares the two refusals the service can answer" do
    missing = documented_operations.filter_map { |_method, path|
      next if path == "/v1/webhooks/stripe"

      operation = operation_at(path)
      absent = %w[401 503] - operation.fetch("responses").keys
      [ path, absent ] if absent.any?
    }

    assert_empty missing.map { |path, absent| "#{path} does not declare #{absent.join(", ")}" },
      "these /v1 operations do not declare the statuses a missing token produces. A client " \
      "generated from this document would have no 401 and no 503 to handle."
  end

  test "the webhook is the only operation that declares no security, and says why" do
    overridden = documented_operations.filter_map { |_method, path|
      operation = operation_at(path)
      next unless operation.key?("security")

      [ path, operation.fetch("security") ]
    }

    assert_equal [ [ "/v1/webhooks/stripe", [] ] ], overridden,
      "an operation declared its own `security`. The only one that may is the Stripe " \
      "webhook, whose sender is a processor authenticated by signature; a second would be " \
      "a second trust path to a door this service already has one for."
  end

  # The webhook's `security: []` is a declaration, and a declaration nobody reads is a
  # comment. Asserted that its own description says *why* it is unauthenticated, so a
  # reader who lands on the operation is told rather than left to infer.
  test "the webhook says why it is not token-authenticated, in its own description" do
    description = operation_at("/v1/webhooks/stripe").fetch("description")

    assert_match(/signature/i, description,
      "the webhook's description no longer says how it authenticates. `security: []` on an " \
      "operation that never explains itself is the declaration a reader is least likely to " \
      "trust.")
  end

  # The catalogue is the one place the document must not overstate what is enforced, so
  # it is asserted: the plan operations say they are not capability-checked. A document
  # that implied the whole surface were authorized would be the same lie as `security: []`
  # in the other direction.
  test "the plan writes say they are not capability-checked, because they are not" do
    %w[createPlan updatePlan].each do |operationId|
      description = operation_by_id(operationId).fetch("description", "")

      assert_match(/scope/i, description,
        "#{operationId} does not mention capability. A plan has no `account_id`, so the only " \
        "thing that could stop an authenticated caller rewriting every account's pricing is " \
        "a `scopes` check, and this build enforces none.")
    end
  end

  private
    # The operation object at a document path, which may be a single `get` or may hold
    # several verbs under one path item. The path is unique per verb here, so taking the
    # first is unambiguous — and raising rather than defaulting means a path item with
    # no operation under it is a failure rather than a nil.
    def operation_at(path)
      item = path_items.fetch(path)
      verbs = item.slice(*OPERATION_KEYS)
      raise "#{path} declares no operation" if verbs.empty?

      verbs.values.first
    end

    # The one operation carrying `operationId`, found by id rather than by path so a
    # rename in the document cannot quietly point this test at a different operation.
    # `sole` rather than `first`: two operations sharing an id is the very thing the
    # test above forbids, and a `first` here would let it through by answering anyway.
    def operation_by_id(operationId)
      found = path_items.flat_map { |_path, item|
        item.filter_map { |key, operation|
          next unless OPERATION_KEYS.include?(key)
          next unless operation.is_a?(Hash) && operation["operationId"] == operationId

          operation
        }
      }

      raise "#{operationId} names #{found.size} operations" if found.size != 1

      found.sole
    end

  # --- the manifest ---------------------------------------------------------

  test "the manifest declares an api, and the document it points at exists" do
    assert_path_exists Rails.root.join(manifest.fetch("exposes").fetch("api"))
  end

  private
    # --- the two sides, read the same way -------------------------------------

    # `safe_load_file`, not `load_file`: the document and the manifest are both
    # data this service reads and neither is allowed to construct an object by
    # being parsed. Aliases are refused for the same reason the manifest's reader
    # refuses them — a document that needs an alias to say what it says is not a
    # document a reader can diff.
    def document
      @document ||= YAML.safe_load_file(Rails.root.join(DOCUMENT), permitted_classes: [], aliases: false)
    end

    def manifest
      @manifest ||= YAML.safe_load_file(Rails.root.join(MANIFEST), permitted_classes: [], aliases: false)
    end

    # Every path item in the document, checked for keys this test does not model.
    #
    # A key it does not understand is a **raise**, not a skip: a check that
    # quietly ignores a key reports "the document and the router agree" for an
    # operation it never compared, which is the outcome a contract test exists to
    # prevent. The two lists are the whole Path Item Object, so a key the
    # specification grows tomorrow fails here once, by name.
    def path_items
      @path_items ||= document.fetch("paths").tap { |paths|
        paths.each do |path, item|
          unreadable = item.keys - OPERATION_KEYS - NOT_OPERATION_KEYS

          raise "#{path} has #{unreadable.inspect}, which this test does not model: teach it, or it silently stops checking that operation" if unreadable.any?
        end
      }
    end

    # Every operation the document declares, keyed by `[method, path]` so the
    # direction of a difference can be reported by name, valued by the operationId
    # it declares — `nil` where it declares none, which is the breach
    # `unnamed_operations` reports.
    def documented
      @documented ||= path_items.flat_map { |path, item|
        item.filter_map { |key, operation|
          next unless OPERATION_KEYS.include?(key)

          [ [ key.upcase, path ], operation.is_a?(Hash) ? operation["operationId"] : nil ]
        }
      }.to_h
    end

    # `(method, path)` for every declared operation.
    def documented_operations
      @documented_operations ||= documented.keys.to_set
    end

    # Every `(method, path)` the router serves, in the same spelling.
    def served
      @served ||= Rails.application.routes.routes.flat_map { |route|
        path = document_path(route.path.spec.to_s)

        methods_for(route).map { |method| [ method, path ] }
      }.to_set
    end

    def operation_ids
      documented.values
    end

    # Declared by the document, not served by the router: one direction of the
    # difference. Named rather than left as a subtraction so a failure says which
    # side moved.
    def declared_and_unserved
      documented_operations - served
    end

    # Served by the router, declared by neither the document nor the exclusion
    # list: the other direction, and the one that catches a route nobody argued
    # about.
    def served_and_unexplained
      served - NOT_A_CLIENT_OPERATION.keys - documented_operations
    end

    # An exclusion for a route that has gone away. It excludes nothing today and
    # will exclude the next route somebody adds at that path, which is why it is
    # reported rather than left to rot.
    def stale_exclusions
      NOT_A_CLIENT_OPERATION.keys.reject { |operation| served.include?(operation) }
    end

    def unnamed_operations
      documented.select { |_operation, id| id.nil? || id.to_s.empty? }.keys.to_set
    end

    # --- reading the router ---------------------------------------------------

    # `:id` in Rails is `{id}` in the document, and the substitution is exact: a
    # Rails `:slug` becomes `{slug}`, so `/v1/plans/:slug` cannot satisfy
    # `/v1/plans/{id}` and the two lookups a plan deliberately has are two
    # operations here. `(.:format)` is Rails' own optional format segment and has
    # no counterpart in the document.
    def document_path(path)
      path.sub("(.:format)", "").gsub(/:([a-z_]+)/) { "{#{Regexp.last_match(1)}}" }
    end

    # The methods one route answers. An empty verb is `via: :all` and answers
    # every method; `via: [:get, :post]` reaches the router as one route whose
    # verb is `GET|POST`.
    def methods_for(route)
      route.verb.empty? ? EVERY_METHOD : route.verb.split("|")
    end

    # Every route drawn to a controller with no verb constraint. A **mount** carries
    # no controller — ActionCable's `/cable` is one — and `recognize_path` cannot
    # see a mount, which is matched on a prefix rather than recognised as a
    # route. Those are excluded by path above, with their own reason; this is the
    # set whose expansion of `EVERY_METHOD` is checked against the router.
    def unconstrained_routes
      Rails.application.routes.routes.select { |route| route.verb.empty? && route.defaults[:controller].present? }
    end

    def recognizes?(route, method)
      Rails.application.routes.recognize_path(document_path(route.path.spec.to_s), method: method.downcase.to_sym)
      true
    rescue ActionController::RoutingError
      false
    end

    # --- naming a failure -----------------------------------------------------

    # `GET /v1/plans/{id}` rather than `["GET", "/v1/plans/{id}"]`: the pair is
    # the thing being reported and a request line is how it reads.
    def names(operations)
      operations.map { |method, path| "#{method} #{path}" }.sort.join(", ")
    end
end
