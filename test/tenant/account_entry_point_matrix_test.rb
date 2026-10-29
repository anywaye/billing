require "test_helper"

class TenantAccountEntryPointMatrixTest < ActiveSupport::TestCase
  KINDS = %w[read list write update delete].freeze

  TENANT_MODELS = %w[Customer Charge Plan Subscription].freeze

  PAYLOAD_TENANT_MODELS = %w[OutboxEvent].freeze

  ACCOUNT_SCOPED_ROUTES = {
    [ "GET", "/v1/customers" ] => [ "list", "returns this account's customers, scoped by `for_account`" ],
    [ "POST", "/v1/customers" ] => [ "write", "writes a customer owned by the token's account, never by a body field" ],
    [ "GET", "/v1/customers/:id" ] => [ "read", "resolves a customer by its uuid inside `for_account`; another account's is a 404" ],
    [ "PATCH", "/v1/customers/:id" ] => [ "update", "writes a customer resolved inside `for_account`" ],

    [ "GET", "/v1/plans" ] => [ "list", "returns the whole catalogue, which is platform-wide and carries no account" ],
    [ "POST", "/v1/plans" ] => [ "write", "writes the catalogue every account is offered" ],
    [ "GET", "/v1/plans/:slug" ] => [ "read", "reads the catalogue by handle" ],
    [ "PATCH", "/v1/plans/:id" ] => [ "update", "writes the catalogue by uuid" ],

    [ "GET", "/v1/subscriptions" ] => [ "list", "returns this account's subscriptions, scoped by `for_account`" ],
    [ "POST", "/v1/subscriptions" ] => [ "write", "resolves the `customer_id` in the body inside `Customer.for_account`" ],
    [ "GET", "/v1/subscriptions/:id" ] => [ "read", "resolves a subscription by its uuid inside `for_account`; another account's is a 404" ],
    [ "POST", "/v1/subscriptions/:id/cancel" ] => [ "update", "cancels a subscription resolved inside `for_account`" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ] => [ "update", "moves a subscription resolved inside `for_account` onto another plan" ],

    [ "GET", "/v1/subscriptions/:id/upcoming_invoice" ] => [ "read", "projects the next invoice for a subscription resolved inside `for_account`; another account's is a 404 and the processor is not asked" ],
    [ "POST", "/v1/subscriptions/:id/payment_method" ] => [ "update", "opens the processor's portal for a subscription resolved inside `for_account`; another account's is a 404 and no portal is asked for" ],
    [ "GET", "/v1/subscriptions/:id/entitlements" ] => [ "read", "reads entitlements for a subscription resolved inside `for_account`" ],

    [ "GET", "/v1/charges" ] => [ "list", "pages this account's charges, scoped by `Charge.for_account`; another account's is not in the listing" ],
    [ "GET", "/v1/charges/:id" ] => [ "read", "resolves a charge by its uuid inside `for_account`; another account's is a 404" ],

    [ "POST", "/v1/checkouts" ] => [ "write", "completes a checkout for the `customer_id` in the body, resolved inside `Customer.for_account`" ],

    [ "GET", "/v1/token_wallet" ] => [ "read", "reads the authenticated account's token balance via ask-tokens" ],
    [ "GET", "/v1/token_wallet/entries" ] => [ "list", "pages the authenticated account's token ledger via ask-tokens" ],
    [ "POST", "/v1/token_wallet/grant" ] => [ "write", "grants tokens to the authenticated account's wallet via ask-tokens" ],
    [ "POST", "/v1/token_wallet/deduct" ] => [ "write", "deducts tokens from the authenticated account's wallet via ask-tokens" ],
    [ "POST", "/v1/token_wallet/adjust" ] => [ "update", "adjusts the authenticated account's token balance via ask-tokens" ]
  }.freeze

  NOT_ACCOUNT_SCOPED_ROUTES = {
    [ "POST", "/v1/webhooks/stripe" ] =>
      "authenticates the processor by signature, not a anywaye client, and must never grow a token check"
  }.freeze

  DATA_ACCESSES = {
    [ "app/controllers/v1/customers_controller.rb", "index", "list" ] => "pages this account's customers, scoped by `Customer.for_account`",
    [ "app/controllers/v1/customers_controller.rb", "create", "write" ] => "creates a customer owned by the token's account, never by a body field",
    [ "app/controllers/v1/customers_controller.rb", "update", "update" ] => "writes a customer resolved inside `for_account`",
    [ "app/controllers/v1/customers_controller.rb", "customer_record", "read" ] => "resolves a customer by its uuid inside `for_account`",
    [ "app/controllers/v1/plans_controller.rb", "index", "list" ] => "reads the whole catalogue, which is platform-wide and carries no account",
    [ "app/controllers/v1/plans_controller.rb", "create", "write" ] => "creates a catalogue row, which every account is then offered",
    [ "app/controllers/v1/plans_controller.rb", "show", "read" ] => "resolves a catalogue row by its slug",
    [ "app/controllers/v1/plans_controller.rb", "plan_record", "read" ] => "resolves a catalogue row by its uuid",
    [ "app/controllers/v1/plans_controller.rb", "update", "update" ] => "writes a catalogue row by its uuid",
    [ "app/controllers/v1/subscriptions_controller.rb", "index", "list" ] => "pages this account's subscriptions, scoped by `Subscription.for_account`",
    [ "app/controllers/v1/subscriptions_controller.rb", "subscription_record", "read" ] => "resolves a subscription by its uuid inside `for_account`; every row-addressed action comes through here",
    [ "app/controllers/v1/subscriptions_controller.rb", "billable_customer", "read" ] => "resolves the customer the body names, inside `Customer.for_account`",
    [ "app/controllers/v1/checkouts_controller.rb", "billable_customer", "read" ] => "resolves the `customer_id` in the body inside `Customer.for_account`; another account's customer cannot be completed for",
    [ "app/controllers/v1/checkouts_controller.rb", "sellable_plan", "read" ] => "resolves the plan the body names, which is catalogue and unscoped",
    [ "app/controllers/v1/subscriptions_controller.rb", "sellable_plan", "read" ] => "resolves the plan the body names, which is catalogue and unscoped",
    [ "app/controllers/v1/subscriptions_controller.rb", "cancel", "update" ] => "asks the processor to cancel a subscription resolved inside `for_account`",
    [ "app/controllers/v1/subscriptions_controller.rb", "change_plan", "update" ] => "asks the processor to move a subscription resolved inside `for_account`",
    [ "app/controllers/v1/subscriptions_controller.rb", "upcoming_invoice", "read" ] => "projects the next invoice for a subscription resolved inside `for_account`; the subscription read is `subscription_record`'s, and this asks the processor a question",
    [ "app/controllers/v1/subscriptions_controller.rb", "payment_method", "update" ] => "opens the processor's portal for a subscription resolved inside `for_account`; the customer the portal is for comes off the row, never off the body",

    [ "app/services/subscriptions/lifecycle.rb", "call", "read" ] => "resolves the row a delivery writes, by the processor's subscription id",
    [ "app/services/subscriptions/lifecycle.rb", "customer", "read" ] => "resolves a customer from a delivery, by anywaye id or by Stripe id",
    [ "app/services/subscriptions/lifecycle.rb", "plan", "read" ] => "resolves a plan from a delivery by its Stripe price id",
    [ "app/services/subscriptions/lifecycle.rb", "apply", "write" ] => "builds the subscription row a delivery created",
    [ "app/services/subscriptions/lifecycle.rb", "apply", "update" ] => "writes the resolved customer's account onto that row",

    [ "app/models/customer.rb", "publish_created", "write" ] => "writes `billing.customer.created` for the created customer",
    [ "app/models/plan.rb", "publish_created", "write" ] => "writes `billing.plan.created`",
    [ "app/models/plan.rb", "publish_updated", "write" ] => "writes `billing.plan.updated`",
    [ "app/services/webhooks/ingestion.rb", "emit", "write" ] => "writes whichever event the delivery's resolved account produced",

    [ "app/services/checkout/session.rb", "recorded", "write" ] => "writes `billing.subscription.started` for the account the checkout's customer is owned by",

    [ "app/models/charge.rb", "belongs_to :customer", "read" ] => "declares the join to the account-scoped customer the charge is billed to",
    [ "app/models/charge.rb", "belongs_to :subscription", "read" ] => "declares the join to the subscription the charge is for, which is absent for a one-time checkout",
    [ "app/models/charge.rb", "scope :for_account", "list" ] => "resolves one account's charges by `account_id`, the tenancy key the receipt route reads through",
    [ "app/services/webhooks/charges/recorder.rb", "find_customer", "read" ] => "resolves the anywaye customer a payment is for, by anywaye id or by processor id",
    [ "app/services/webhooks/charges/recorder.rb", "resolved_subscription", "read" ] => "resolves the subscription a payment is for, by the processor's subscription id",
    [ "app/services/webhooks/charges/recorder.rb", "record", "write" ] => "writes the charge a settled payment is the receipt for",
    [ "app/controllers/v1/charges_controller.rb", "show", "read" ] => "resolves a charge by its uuid inside `for_account`; another account's is a 404",
    [ "app/controllers/v1/charges_controller.rb", "index", "list" ] => "pages this account's charges, scoped by `Charge.for_account`",

    [ "app/services/webhooks/stripe_events.rb", "find_customer", "read" ] => "resolves the anywaye customer a payment is for, by anywaye id or by processor id, for the recipient fact on the event",

    [ "app/controllers/concerns/cursor_paging.rb", "apply_cursor", "list" ] => "applies a client-supplied keyset to a relation the caller chose",

    [ "app/services/webhooks/account_resolution.rb", "find_customer", "read" ] => "resolves the customer a verified processor event names, by the value the payload carried — the lookup the resolve policy widens to one row, and the only read in app/ that runs with no account identity at all",

    [ "app/models/subscription.rb", "belongs_to :customer", "read" ] => "declares the join to the account-scoped customer row",
    [ "app/models/subscription.rb", "belongs_to :plan", "read" ] => "declares the join to the catalogue row the subscription is billed against",

    [ "app/models/customer.rb", "scope :for_account", "list" ] => "resolves one account's customers by `owner_type: Account` and `owner_id`; a `User`-owned customer is in no account and is excluded",
    [ "app/models/subscription.rb", "scope :for_account", "list" ] => "resolves one account's subscriptions by `account_id`, which is the tenancy key every row-addressed action reads through",

    [ "app/models/subscription.rb", "scope :live", "list" ] => "resolves a subscription's live rows; carries no account and is not meant to",
    [ "app/models/subscription.rb", "scope :canceled", "list" ] => "resolves a subscription's canceled rows; carries no account and is not meant to",
    [ "app/models/outbox_event.rb", "scope :unpublished", "list" ] => "resolves unpublished outbox rows, whose payloads carry every account's events",
    [ "app/models/outbox_event.rb", "scope :oldest_first", "list" ] => "orders outbox rows for the publisher loop, which now exists: `Outbox::Relay` starts it when NATS_URL names a broker",
    [ "app/models/outbox_event.rb", "scope :for_processor_event", "list" ] => "resolves outbox rows by a processor event id, never by an account"
  }.freeze

  NO_DATA_ACCESS = {
    "app/controllers/application_controller.rb" => "assembles the shared response concerns; it queries nothing",
    "app/controllers/concerns/authenticates_principal.rb" => "the `/v1` boundary: it reads a bearer token and renders a refusal, and it reaches no tenant row on either path",
    "app/lib/principal.rb" => "the verified caller as a value; it holds an account id and reads no model",
    "app/services/identity.rb" => "the identity namespace and its three refusal classes; it holds no query",
    "app/services/courier/type_registrar.rb" => "registers billing's notification types in courier over HTTP; it holds no row in this database",
    "app/services/identity/token_verifier.rb" => "verifies a signature against identity's published key set, which is not this service's data",
    "app/controllers/concerns/idempotent_requests.rb" => "replays a response this service already sent, keyed on the request's own idempotency key",
    "app/controllers/concerns/problem_responses.rb" => "renders problem documents for a status a controller chose",
    "app/controllers/concerns/request_trace_id.rb" => "stamps a trace id on a response; it queries nothing",
    "app/controllers/errors_controller.rb" => "renders a problem document for a status Rails raised; it queries nothing",
    "app/controllers/health_controller.rb" => "the readiness probe reads a connection, not a tenant's rows",
    "app/controllers/v1/base_controller.rb" => "the uuid shape check on a path segment; it runs before the query, on purpose",
    "app/controllers/webhooks/base_controller.rb" => "the webhook's shared signature seam; it queries nothing",
    "app/controllers/webhooks/stripe_controller.rb" => "verifies the raw body and hands it to ingestion; every row it implies is ingestion's",
    "app/jobs/application_job.rb" => "the abstract base class; it declares no query",
    "app/lib/idempotency_key_reused.rb" => "the error a replayed key raises; it holds no query",
    "app/lib/identifiers.rb" => "the uuid shape in one place; it reads no model",
    "app/lib/money_params.rb" => "turns a request body into an amount; it reads no model",
    "app/models/account.rb" => "a non-persisted value object referencing an identity account; it reads no model",
    "app/controllers/v1/token_wallets_controller.rb" => "delegates all data access to ask-tokens\' ActiveRecord store; no direct model call in this file",
    "app/lib/parameter_error.rb" => "the error a bad query parameter raises; it holds no query",
    "app/lib/problem.rb" => "the problem vocabulary, a frozen table of codes and no model access",
    "app/lib/tenancy.rb" => "writes the transaction-local identity the row level security policies read; it opens no query of its own and touches no table",
    "app/mailers/application_mailer.rb" => "the abstract base class; it declares no query",
    "app/models/application_record.rb" => "the abstract base class; it declares no scope",
    "app/models/idempotency_key.rb" => "keyed on the request's own idempotency key, which is a client's, not an account's. Its `scope :expired` is a ttl and touches no tenant row, which is why a scope on a non-tenant model is not counted.",
    "app/models/billing/money.rb" => "the money primitive; it reads no model",
    "app/models/processor_webhook.rb" => "the receipt model; its one write is `ingest`, addressed by the processor's event id",
    "app/services/processor.rb" => "the processor namespace; it declares no query",
    "app/services/processor/stripe_client.rb" => "builds and sends the three processor requests; the row each acts on was resolved by the caller",
    "app/services/processor/fake_client.rb" => "answers a checkout with a value object; the value it constructs is `Processor::FakeClient::ProcessorSubscription`, not the `subscriptions` table, and it reads and writes no model at all",
    "app/services/subscriptions.rb" => "the subscriptions namespace; it declares no query",
    "app/services/subscriptions/plan_change.rb" => "compares two prices and decides timing; pure, no model access",
    "app/services/subscriptions/state_machine.rb" => "a from-status and a to-status in, an answer out; pure, no model access",
    "app/services/webhooks.rb" => "the webhooks namespace; it declares no query",
    "app/services/checkout.rb" => "the checkout namespace; it declares no query",
    "app/services/webhooks/emission.rb" => "the value object a handler returns; it holds no query",
    "app/services/outbox.rb" => "the outbox namespace and its configuration refusal; it declares no query",
    "app/services/outbox/nats_publisher.rb" => "puts an envelope on the broker and waits for the ack; it holds no model and the payload is never read back out of it",
    "app/services/outbox/relay.rb" => "the loop and the boot condition: it resolves the shared gem's publisher over the outbox connection pool, and the claim and the marks are the gem's SQL over the account-less outbox table, not this file's"
  }.freeze


  Access = Data.define(:path, :method, :kind, :expression) do
    def site = [ path, method ]

    def key = [ path, method, kind ]

    def to_s = "#{path}##{method} (#{expression}, #{kind})"
  end

  ACCESS_EXPRESSIONS = [
    [ "read",   /\b(?:Customer|Charge|Plan|Subscription)\.for_account\([^)]*\)\s*\.\s*(?:find|find_by|find_by!)\(/ ],
    [ "read",   /\b(?:Customer|Charge|Plan|Subscription)\.(?:find|find_by|find_by!)\(/ ],
    [ "read",   /\bbelongs_to\s+:[a-z_]/ ],
    [ "list",   /\b(?:Customer|Charge|Plan|Subscription)\.for_account\(/ ],
    [ "list",   /\b(?:Customer|Charge|Plan|Subscription)\.all\b/ ],
    [ "list",   /\bscope\s+:[a-z_]+,\s*->/ ],
    [ "list",   /\bscope\.where\(/ ],
    [ "write",  /\b(?:Customer|Charge|Plan|Subscription)\.(?:new\b|create!)/ ],
    [ "write",  /\bOutboxEvent\.publish!/ ],
    [ "update", /\bassign_attributes\b/ ],
    [ "update", /\bprocessor\.(?:cancel_subscription|apply_plan_change)\(/ ],
    [ "read",   /\bprocessor(?:_for\([^)]*\))?\.upcoming_invoice\(/ ],
    [ "update", /\bprocessor(?:_for\([^)]*\))?\.billing_portal_url\(/ ]
  ].freeze

  TENANT_MODEL_ONLY_EXPRESSIONS = [
    [ "read",   /\bbelongs_to\s+:[a-z_]/ ],
    [ "list",   /\bscope\s+:[a-z_]+,\s*->/ ]
  ].freeze

  class << self
    def accesses
      @accesses ||= source_files.flat_map { |path| accesses_in(path) }
    end

    def source_files
      @source_files ||= Dir[Rails.root.join("app/**/*.rb")].sort.map { |path|
        Pathname(path).relative_path_from(Rails.root).to_s
      }
    end

    private
      def accesses_in(path)
        found = []
        method = "(file scope)"
        source = Rails.root.join(path).read
        patterns = patterns_for(source)

        source.each_line.with_index(1) do |line, _number|
          if (named = line.match(/^\s*def\s+(?:self\.)?([a-z_][A-Za-z0-9_]*[?!]?)/))
            method = named[1]
          elsif (declaration = line.match(/^\s*belongs_to\s+:([a-z_]+)/))
            method = "belongs_to :#{declaration[1]}"
          elsif (declaration = line.match(/^\s*scope\s+:([a-z_]+)/))
            method = "scope :#{declaration[1]}"
          end
          next if line.strip.start_with?("#")

          patterns.each do |kind, pattern|
            match = pattern.match(line)
            next unless match

            found << Access.new(path, method, kind, match[0].sub(/\($/, "").strip)
            break
          end
        end

        found
      end

      def patterns_for(source)
        declares_tenant_query = source.match?(/\b(?:belongs_to\s+:|scope\s+:[a-z_]+,\s*->)/)
        return ACCESS_EXPRESSIONS if declares_tenant_query && declared_tenant_model?(source)

        ACCESS_EXPRESSIONS - TENANT_MODEL_ONLY_EXPRESSIONS
      end

      def declared_tenant_model?(source)
        (TENANT_MODELS + PAYLOAD_TENANT_MODELS).include?(declaring_model(source))
      end

      def declaring_model(source)
        source[/^class\s+([A-Z][A-Za-z0-9_]*)\s*<\s*ApplicationRecord/, 1]
      end
  end


  test "every data access in app is an account-scoped entry point" do
    unclassified = self.class.accesses.reject { |access| DATA_ACCESSES.key?(access.key) || NO_DATA_ACCESS.key?(access.path) }

    assert_empty unclassified.map(&:to_s),
      "these data accesses are in app/ and in no table. Decide whether each is " \
      "account-scoped: add it to DATA_ACCESSES with its kind and what it touches, or " \
      "name the file in NO_DATA_ACCESS with the reason it is not."
  end

  test "every entry point this matrix classifies is one the source still has" do
    assert_empty classified_sites - self.class.accesses.map(&:site).uniq,
      "these entry points are classified for a method that no longer exists. A method " \
      "that went away takes its scope classification with it."
  end

  test "every data access's kind is one this matrix claims for that method" do
    claimed = DATA_ACCESSES.keys.group_by { |path, method, _kind| [ path, method ] }
      .transform_values { |rows| rows.map { |(_path, _method, kind)| kind } }

    unclaimed = self.class.accesses.reject { |access| claimed.fetch(access.site, []).include?(access.kind) }

    assert_empty unclaimed.map(&:to_s),
      "these accesses are in a method this matrix classifies, but at a kind it does not " \
      "claim for it. A method that grew an access of another kind needs its own row."
  end


  test "there are 52 account-scoped data accesses in 48 methods, filed under 49 keys" do
    assert_equal 52, self.class.accesses.size
    assert_equal 48, classified_sites.size
    assert_equal 49, DATA_ACCESSES.size

    assert_equal 3, self.class.accesses.size - DATA_ACCESSES.size,
      "the gap between accesses and keys has changed. It is 3 because `Lifecycle#customer`, " \
      "`Recorder#find_customer` and `AccountResolution#find_customer` each do two lookups under " \
      "one description; a different number means a method is doing something the table no longer " \
      "describes."

    assert_equal 1, DATA_ACCESSES.size - classified_sites.size,
      "the gap between keys and methods has changed. It is 1 because `Lifecycle#apply` " \
      "both creates and writes; a different number means a method is doing something the " \
      "table no longer describes."
  end

  test "the data-access breakdown is read 24, list 13, write 9, update 6, delete 0" do
    assert_equal({ "read" => 24, "list" => 13, "write" => 9, "update" => 6, "delete" => 0 }, breakdown(self.class.accesses.map(&:kind)))
  end

  test "there are 24 account-scoped routes, and the router serves exactly them plus the webhook" do
    assert_equal 24, ACCOUNT_SCOPED_ROUTES.size
    assert_equal served_routes.to_set,
                 (ACCOUNT_SCOPED_ROUTES.keys + NOT_ACCOUNT_SCOPED_ROUTES.keys).to_set
  end

  test "no route is both account-scoped and not" do
    assert_empty (ACCOUNT_SCOPED_ROUTES.keys & NOT_ACCOUNT_SCOPED_ROUTES.keys).map { |method, path| "#{method} #{path}" }
  end

  test "every route that is not account-scoped says why it is not" do
    unexplained = NOT_ACCOUNT_SCOPED_ROUTES.select { |(_operation), reason| reason.to_s.strip.empty? }

    assert_empty unexplained.keys.map { |method, path| "#{method} #{path}" },
      "these routes are excluded with no reason"
  end

  test "the route breakdown is read 7, list 5, write 6, update 6, delete 0" do
    assert_equal({ "read" => 7, "list" => 5, "write" => 6, "update" => 6, "delete" => 0 },
                 breakdown(ACCOUNT_SCOPED_ROUTES.values.map(&:first)))
  end

  test "the two layers are counted separately, because a route and the method that serves it overlap" do
    assert_equal 24, ACCOUNT_SCOPED_ROUTES.size
    assert_equal 52, self.class.accesses.size
    refute_equal ACCOUNT_SCOPED_ROUTES.size, self.class.accesses.size,
      "the two layers have converged, which means one of them is counting the other's rows"
  end


  test "delete is zero in app, and the router serves no DELETE under /v1" do
    destroyers = source_lines.select { |line| line.match?(/\b(?:destroy|destroy_all|delete_all)\b/) }

    assert_empty destroyers,
      "app/ now destroys a row. Destroying is a delete, it needs an account scope like " \
      "any other access, and the breakdown in this file is now wrong: " \
      "#{killers(destroyers).join(", ")}"

    assert_empty served_routes.select { |method, _path| method == "DELETE" }.map { |_method, path| path },
      "the router now serves a DELETE under /v1. A delete is an operation kind with its " \
      "own scope, and it must be classified here and covered by a negative test."
  end


  test "every account-scoped route names a kind this file knows" do
    unknown = ACCOUNT_SCOPED_ROUTES.reject { |(_operation), (kind, _why)| KINDS.include?(kind) }

    assert_empty unknown.keys.map { |method, path| "#{method} #{path}" },
      "these routes name a kind outside #{KINDS.inspect}"
  end

  test "every account-scoped route says why it is account-scoped" do
    unexplained = ACCOUNT_SCOPED_ROUTES.select { |(_operation), (_kind, why)| why.to_s.strip.empty? }

    assert_empty unexplained.keys.map { |method, path| "#{method} #{path}" },
      "these routes are account-scoped with no reason given. A route with no stated " \
      "reason is a route nobody thought about."
  end

  test "every data access names a kind this file knows" do
    unknown = DATA_ACCESSES.keys.reject { |(_path, _method, kind)| KINDS.include?(kind) }

    assert_empty unknown.map { |path, method, kind| "#{path}##{method} (#{kind})" },
      "these data accesses name a kind outside #{KINDS.inspect}"
  end

  test "every data access says what it touches" do
    unexplained = DATA_ACCESSES.select { |(_path, _method, _kind), what| what.to_s.strip.empty? }

    assert_empty unexplained.keys.map { |path, method, kind| "#{path}##{method} (#{kind})" },
      "these data accesses have no explanation. An access with no stated reason is an " \
      "access nobody thought about."
  end

  test "every file excluded from the scan says why it is excluded" do
    unexplained = NO_DATA_ACCESS.select { |_path, reason| reason.to_s.strip.empty? }

    assert_empty unexplained.keys, "these files are excluded with no reason"
  end

  test "every file in app either performs a data access or is named with a reason" do
    performing = self.class.accesses.map(&:path).uniq

    assert_empty self.class.source_files - performing - NO_DATA_ACCESS.keys,
      "these files perform no data access and are not named in NO_DATA_ACCESS. A file " \
      "that touches no row does not need an account scope, but it does need to be said so."
  end

  test "no file excluded from the scan performs a data access" do
    offenders = NO_DATA_ACCESS.keys.select { |path| self.class.accesses.any? { |access| access.path == path } }

    assert_empty offenders,
      "these files are excluded as performing no data access and now perform one. Give " \
      "the access an entry point and a scope, and drop the exclusion."
  end

  test "the models this treats as tenant data are the four account-scoped ones" do
    assert_equal %w[Customer Charge Plan Subscription], TENANT_MODELS
    assert_equal(
      { "Customer" => Customer, "Charge" => Charge, "Plan" => Plan, "Subscription" => Subscription },
      TENANT_MODELS.to_h { |name| [ name, name.constantize ] }
    )
  end

  test "the payload-carrying set is the outbox alone, and it has no account column to scope by" do
    assert_equal %w[OutboxEvent], PAYLOAD_TENANT_MODELS
    refute_includes OutboxEvent.column_names, "account_id",
      "the outbox grew an `account_id` column. That is the publisher loop's decision to " \
      "make, and it would move OutboxEvent into TENANT_MODELS and give the outbox a " \
      "column to scope a read by — at which point this file's outbox row is out of date."
  end

  private
    def classified_sites
      DATA_ACCESSES.keys.map { |path, method, _kind| [ path, method ] }.uniq
    end

    def breakdown(kinds)
      KINDS.index_with { |kind| kinds.count(kind) }
    end

    def served_routes
      @served_routes ||= Rails.application.routes.routes.flat_map { |route|
        path = route.path.spec.to_s.sub("(.:format)", "")
        next [] unless path.start_with?("/v1")

        methods_for(route).map { |method| [ method, path ] }
      }.uniq
    end

    def methods_for(route)
      route.verb.empty? ? %w[GET HEAD POST PUT PATCH DELETE OPTIONS] : route.verb.split("|")
    end

    def source_lines
      self.class.source_files.flat_map { |path| Rails.root.join(path).read.lines }
    end

    def killers(lines)
      lines.map { |line| line.strip[0, 80] }
    end
end
