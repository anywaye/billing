require "test_helper"

class HttpSurfaceContractTest < ActiveSupport::TestCase
  DOCUMENT = "openapi/v1.yaml"
  MANIFEST = "anywaye.yml"


  EVERY_METHOD = %w[GET HEAD POST PUT PATCH DELETE OPTIONS].freeze

  def self.every_method(path, reason)
    EVERY_METHOD.to_h { |method| [ [ method, path ], reason ] }
  end

  HEALTH_PROBE = "Infrastructure, not contract surface: not in `anywaye.yml`'s " \
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
    "table in `db/schema.rb` and uses neither, so none of these is a anywaye " \
    "operation and none is described here. They are listed rather than filtered by " \
    "prefix because a route that appears without somebody adding it and writing " \
    "down why is the failure this file exists to catch."

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


  OPERATION_KEYS = %w[get put post delete options head patch trace].freeze

  NOT_OPERATION_KEYS = %w[$ref summary description servers parameters].freeze


  OPERATION_IDS = %w[
    adjustTokenWallet
    cancelSubscription
    changeSubscriptionPlan
    createCheckout
    createCustomer
    createPaymentMethodUrl
    createPlan
    createSubscriptionCheckout
    deductTokens
    getCharge
    getCustomer
    getPlan
    getSubscription
    getSubscriptionEntitlements
    getTokenWallet
    getUpcomingInvoice
    grantTokens
    listCharges
    listCustomers
    listPlans
    listSubscriptions
    listTokenWalletEntries
    receiveStripeWebhook
    updateCustomer
    updatePlan
  ].freeze

  test "every operation the document declares is served, and every operation served is declared" do
    breaches = []
    breaches << "declared by the document but not served, so a client generated from it would " \
      "call a 404: #{names(declared_and_unserved)}" if declared_and_unserved.any?
    breaches << "served by the router but neither declared nor named on the exclusion list with " \
      "a reason: #{names(served_and_unexplained)}" if served_and_unexplained.any?

    assert_empty breaches, breaches.join(" — ")
  end

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
    assert_equal "2.5.1", document.fetch("info").fetch("version")
  end


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

  test "the webhook says why it is not token-authenticated, in its own description" do
    description = operation_at("/v1/webhooks/stripe").fetch("description")

    assert_match(/signature/i, description,
      "the webhook's description no longer says how it authenticates. `security: []` on an " \
      "operation that never explains itself is the declaration a reader is least likely to " \
      "trust.")
  end

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
    def operation_at(path)
      item = path_items.fetch(path)
      verbs = item.slice(*OPERATION_KEYS)
      raise "#{path} declares no operation" if verbs.empty?

      verbs.values.first
    end

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


  test "the manifest declares an api, and the document it points at exists" do
    assert_path_exists Rails.root.join(manifest.fetch("exposes").fetch("api"))
  end

  private

    def document
      @document ||= YAML.safe_load_file(Rails.root.join(DOCUMENT), permitted_classes: [], aliases: false)
    end

    def manifest
      @manifest ||= YAML.safe_load_file(Rails.root.join(MANIFEST), permitted_classes: [], aliases: false)
    end

    def path_items
      @path_items ||= document.fetch("paths").tap { |paths|
        paths.each do |path, item|
          unreadable = item.keys - OPERATION_KEYS - NOT_OPERATION_KEYS

          raise "#{path} has #{unreadable.inspect}, which this test does not model: teach it, or it silently stops checking that operation" if unreadable.any?
        end
      }
    end

    def documented
      @documented ||= path_items.flat_map { |path, item|
        item.filter_map { |key, operation|
          next unless OPERATION_KEYS.include?(key)

          [ [ key.upcase, path ], operation.is_a?(Hash) ? operation["operationId"] : nil ]
        }
      }.to_h
    end

    def documented_operations
      @documented_operations ||= documented.keys.to_set
    end

    def served
      @served ||= Rails.application.routes.routes.flat_map { |route|
        path = document_path(route.path.spec.to_s)

        methods_for(route).map { |method| [ method, path ] }
      }.to_set
    end

    def operation_ids
      documented.values
    end

    def declared_and_unserved
      documented_operations - served
    end

    def served_and_unexplained
      served - NOT_A_CLIENT_OPERATION.keys - documented_operations
    end

    def stale_exclusions
      NOT_A_CLIENT_OPERATION.keys.reject { |operation| served.include?(operation) }
    end

    def unnamed_operations
      documented.select { |_operation, id| id.nil? || id.to_s.empty? }.keys.to_set
    end


    def document_path(path)
      path.sub("(.:format)", "").gsub(/:([a-z_]+)/) { "{#{Regexp.last_match(1)}}" }
    end

    def methods_for(route)
      route.verb.empty? ? EVERY_METHOD : route.verb.split("|")
    end

    def unconstrained_routes
      Rails.application.routes.routes.select { |route| route.verb.empty? && route.defaults[:controller].present? }
    end

    def recognizes?(route, method)
      Rails.application.routes.recognize_path(document_path(route.path.spec.to_s), method: method.downcase.to_sym)
      true
    rescue ActionController::RoutingError
      false
    end


    def names(operations)
      operations.map { |method, path| "#{method} #{path}" }.sort.join(", ")
    end
end
