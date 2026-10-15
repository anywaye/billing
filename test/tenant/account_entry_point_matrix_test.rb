require "test_helper"

# Every account-scoped entry point in this service, enumerated and **derived**.
#
# ## Why this file exists beside `contract/tenant_isolation_matrix_test.rb`
#
# That file answers one question about the routes: is this operation
# account-scoped, and is its scope recorded. It does not answer the three this
# file answers, and the rest of the packet is built on all three:
#
#   * **how many** account-scoped entry points there are — not only on the HTTP
#     surface but in the controllers, models and services underneath it;
#   * **what kind** of access each one performs, so "read, list, update, delete"
#     is a count a reader can check rather than a sentence in a report; and
#   * **that the set is total** — a data access nobody classified is an entry
#     point whose scope nobody decided, and it is live on the next deploy.
#
# A negative test is written per entry point, and that count only means
# something if the number of entry points is itself pinned. So the tables below
# are compared against the source in **both directions**: an unclassified data
# access fails here by name, and a classified entry point whose method has gone
# away fails the other way. Neither failure is silent, which is the whole reason
# the tables are derived rather than maintained.
#
# ## Two layers, two numbers, and why they are not added together
#
# A **route** is a caller-facing operation on the HTTP surface: 15 of them. A
# **data access** is one place in `app/` that reads or writes a tenant's row:
# 44 of them, in 41 methods. The two layers overlap — a route is served by a
# controller method that performs a data access — and they are counted separately
# on purpose. Adding them would produce one larger number that means nothing,
# and the two answer different questions: the route count is "how much of the
# surface is a caller's to reach", the data-access count is "how many places hold
# a tenant's row".
#
# billing-12 wrote this when the second number was a to-do list — "how many places
# have to be scoped when identity's JWKS verification lands" — and billing-21 landed
# it. The two account scopes are in the count, the five `/v1` customer and
# subscription reads now go through them, and nothing was removed.
#
# ## Why the derivation is per-method and not per-line
#
# The obvious key is `file:line`, and it is the wrong one: inserting a comment
# renumbers every site below it and turns a documentation edit into a red suite.
# The key is **`path` plus the method the access sits in**, which is the unit a
# reader thinks in — "the `show` action of `V1::CustomersController` reads any
# customer by its uuid" — and which survives the edits that actually happen.
#
# **The kind is part of the key**, because one method can do two kinds of thing
# and `Subscriptions::Lifecycle#apply` does exactly that: it builds a row that did
# not exist and writes to the one that did. A key of `(path, method)` alone would
# force a choice between them and report a smaller number than the code has.
#
# ## What "account-scoped" means here
#
# A data access is account-scoped when it reads or writes a row that belongs to an
# account. Two columns decide it: `Subscription#account_id` and `Charge#account_id`,
# and `Customer#owner_id` when the owner is an `Account`. `Plan` is in the set
# because it is the catalogue every account buys from, and because the contract
# matrix already treats it as tenant data — the same four models, re-pinned here
# so neither file drifts alone.
#
# Twelve of the 44 are **declarations** rather than executed resolutions: the two
# `belongs_to` on `Subscription` and the two on `Charge`, the eight `scope`s on
# `Subscription`, `Customer`, `Charge` and `OutboxEvent`. They are counted,
# because an association and a scope are both queries and leaving a category out
# of an enumeration is how the enumeration stops being one — but they are counted
# as declarations, so a reader who wants only the places a request actually
# reaches a row has **32** and not 44.
#
# A declaration is counted only when the class declaring it holds tenant data:
# `Customer`, `Plan`, `Subscription` (an `account_id` column) or `OutboxEvent` (an
# `account_id` inside `data`). `IdempotencyKey` has a `scope :expired` and is not
# in either set, because it is keyed on the request's own idempotency key and
# touches no tenant row.
#
# `OutboxEvent` is **not** in the tenant-data set and is counted as writes instead,
# for a reason worth stating: an outbox row has no `account_id` of its own. It
# carries one inside `data`, and only because a writer put it there. Nothing in
# this repository reads an outbox row back by account — the publisher loop does
# not exist yet — so the brief's "outbox events" are three writes and zero reads
# here, and that is asserted rather than left to a reader's imagination.
class TenantAccountEntryPointMatrixTest < ActiveSupport::TestCase
  # The kinds an access can have. `delete` is in the vocabulary and its count is
  # asserted to be **zero**, because the alternative — leaving it out of the list
  # — is how "a service that deletes nothing" and "a service that forgot to scope
  # its deletes" come to read the same in a report.
  KINDS = %w[read list write update delete].freeze

  # The models whose rows belong to an account. Pinned, and asserted to be the
  # four the contract matrix pins, so a reader can check the two files agree
  # without opening both.
  TENANT_MODELS = %w[Customer Charge Plan Subscription].freeze

  # The models whose rows **carry** an account without having an account column.
  #
  # `OutboxEvent` is the only one, and the distinction is worth stating rather
  # than smoothing over. An outbox row's `account_id` lives inside `data`, and only
  # because a writer put it there; the table has no `account_id` of its own, so
  # there is nothing for a query to constrain on even today. That is exactly why
  # the outbox answers the brief's "or outbox events" with **three writes and no
  # read by account** — and its three declared scopes are counted here, because a
  # scope over rows that hold every account's events is still a query over tenant
  # data even when the column to scope it by does not exist yet.
  PAYLOAD_TENANT_MODELS = %w[OutboxEvent].freeze

  # Every `/v1` operation the router serves, keyed by `[method, router path]`,
  # with the kind of access it performs and why it is account-scoped.
  #
  # Keyed in the **router's spelling** (`:id`, `:slug`), the same choice
  # `contract/tenant_isolation_matrix_test.rb` makes and for the same reason: a
  # table written in the OpenAPI document's spelling (`{id}`) and compared against
  # the router would report every parameterised route as both unclassified and
  # stale at once, and a reader could not tell which half was wrong.
  #
  # **billing-21 made the first and last groups scoped**, and the value says so
  # rather than leaving a reader to grep for `for_account`: every customer and
  # subscription read is now `Customer.for_account(token.account_id)` or
  # `Subscription.for_account(token.account_id)`, and a uuid naming another account's
  # row is a 404. See `test/authentication/` for the refusals and
  # `test/tenant/cross_account_web_test.rb` for the rewritten characterisations.
  #
  # **The four plan rows are the exception and say why**: a plan is platform
  # catalogue — what an account may buy, not what an account owns — so it carries no
  # account and the routes resolve it by slug or uuid with no filter. That is the
  # model, not a gap; `test/support/two_accounts.rb` shares one plan between both
  # accounts precisely because it is true.
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
    # The two mutating ones. Reading another account's row is a disclosure;
    # cancelling one is a write to it, and it is the expensive direction — which is
    # why both resolve through the same scoped `subscription_record` as the read.
    [ "POST", "/v1/subscriptions/:id/cancel" ] => [ "update", "cancels a subscription resolved inside `for_account`" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ] => [ "update", "moves a subscription resolved inside `for_account` onto another plan" ],

    # The projection: a read of the processor rather than a mutation, and the
    # only route on this controller that asks the processor a question instead
    # of telling it to act.
    [ "GET", "/v1/subscriptions/:id/upcoming_invoice" ] => [ "read", "projects the next invoice for a subscription resolved inside `for_account`; another account's is a 404 and the processor is not asked" ],
    [ "GET", "/v1/subscriptions/:id/entitlements" ] => [ "read", "reads entitlements for a subscription resolved inside `for_account`" ],

    # The receipt for one charge. A charge is billed to an account and the route
    # resolves it inside `Charge.for_account`, so another account's uuid is a 404 —
    # the same answer a uuid naming nothing gets.
    [ "GET", "/v1/charges/:id" ] => [ "read", "resolves a charge by its uuid inside `for_account`; another account's is a 404" ],

    # The development checkout door. It WRITES — a completed checkout grants
    # entitlements — and it resolves the `customer_id` in the body inside
    # `Customer.for_account`, the same resolution the production door's
    # `billable_customer` makes, so another account's customer cannot be
    # completed for. The production door and this one are the same rule over the
    # same scope; only the processor differs.
    [ "POST", "/v1/checkouts" ] => [ "write", "completes a checkout for the `customer_id` in the body, resolved inside `Customer.for_account`" ]
  }.freeze

  # The one `/v1` operation that is served and is **not** account-scoped.
  #
  # Named rather than filtered out of the comparison below, because a filter
  # would go stale silently and then exclude whatever was added at that path
  # next. It authenticates the *processor* by signature, not a cafaye client, and
  # it must never grow a token check: a `Bearer` on that path would be a second,
  # weaker trust path to the same door.
  NOT_ACCOUNT_SCOPED_ROUTES = {
    [ "POST", "/v1/webhooks/stripe" ] =>
      "authenticates the processor by signature, not a cafaye client, and must never grow a token check"
  }.freeze

  # Every data access in `app/`, keyed by `path`, the method it sits in, and its
  # kind, with a statement of what it touches.
  #
  # The second half is not decoration: an access with no stated reason is an
  # access nobody thought about, which is exactly how `/v1/subscriptions` came to
  # return every row.
  DATA_ACCESSES = {
    # --- the /v1 surface -----------------------------------------------------
    # **Every one of these is scoped, and it says so in the value rather than in the
    # key.** billing-21 landed the scoping these entries were the list of, so the
    # twelve `/v1` customer and subscription rows now read `Customer.for_account`
    # and `Subscription.for_account` — the scope carries the account and the reason
    # column records what it is holding to.
    #
    # The four plan rows are the exception and are the interesting ones: a plan is
    # **platform catalogue**, not tenant data, so they carry no account and the reason
    # says so. `test/support/two_accounts.rb` shares one plan between both accounts
    # precisely because that is true, and a plan scoped to an account would have been
    # a bug rather than a fix. See `app/models/plan.rb` and `V1::PlansController`.
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
    # The development checkout door's two resolutions, and they are the same two
    # the production door makes: the buyer is scoped (a cross-account write is
    # the expensive direction), and the plan is catalogue and unscoped. The door
    # being gated off in production is a request filter, not a data access — the
    # row it writes is account-scoped while the door exists.
    [ "app/controllers/v1/checkouts_controller.rb", "billable_customer", "read" ] => "resolves the `customer_id` in the body inside `Customer.for_account`; another account's customer cannot be completed for",
    [ "app/controllers/v1/checkouts_controller.rb", "sellable_plan", "read" ] => "resolves the plan the body names, which is catalogue and unscoped",
    [ "app/controllers/v1/subscriptions_controller.rb", "sellable_plan", "read" ] => "resolves the plan the body names, which is catalogue and unscoped",
    [ "app/controllers/v1/subscriptions_controller.rb", "cancel", "update" ] => "asks the processor to cancel a subscription resolved inside `for_account`",
    [ "app/controllers/v1/subscriptions_controller.rb", "change_plan", "update" ] => "asks the processor to move a subscription resolved inside `for_account`",
    [ "app/controllers/v1/subscriptions_controller.rb", "upcoming_invoice", "read" ] => "projects the next invoice for a subscription resolved inside `for_account`; the subscription read is `subscription_record`'s, and this asks the processor a question",

    # --- the processor delivery path, where an account is resolved from an id -
    [ "app/services/subscriptions/lifecycle.rb", "call", "read" ] => "resolves the row a delivery writes, by the processor's subscription id",
    [ "app/services/subscriptions/lifecycle.rb", "customer", "read" ] => "resolves a customer from a delivery, by cafaye id or by Stripe id",
    [ "app/services/subscriptions/lifecycle.rb", "plan", "read" ] => "resolves a plan from a delivery by its Stripe price id",
    [ "app/services/subscriptions/lifecycle.rb", "apply", "write" ] => "builds the subscription row a delivery created",
    [ "app/services/subscriptions/lifecycle.rb", "apply", "update" ] => "writes the resolved customer's account onto that row",

    # --- the outbox, one writer per producer --------------------------------
    [ "app/models/customer.rb", "publish_created", "write" ] => "writes `billing.customer.created` for the created customer",
    [ "app/models/plan.rb", "publish_created", "write" ] => "writes `billing.plan.created`",
    [ "app/models/plan.rb", "publish_updated", "write" ] => "writes `billing.plan.updated`",
    [ "app/services/webhooks/ingestion.rb", "emit", "write" ] => "writes whichever event the delivery's resolved account produced",

    # --- the checkout path, the second producer of a start ------------------
    # A checkout writes one outbox row, `billing.subscription.started`, for the
    # account whose customer it was made for. It is listed here rather than
    # exempted because it is the **only** other place a start event is written, and
    # an entry point that publishes an account's billing events without an entry
    # here is precisely the thing this matrix exists to notice.
    [ "app/services/checkout/session.rb", "recorded", "write" ] => "writes `billing.subscription.started` for the account the checkout's customer is owned by",

    # --- the charges packet: the receipt for a payment -----------------------
    # A charge is recorded when a payment succeeds and read by the receipt route.
    # The model's two joins and its account scope are declarations, counted for
    # the reason the nine above are; the recorder's lookups and write are the
    # places a delivery actually reaches a tenant's row.
    [ "app/models/charge.rb", "belongs_to :customer", "read" ] => "declares the join to the account-scoped customer the charge is billed to",
    [ "app/models/charge.rb", "belongs_to :subscription", "read" ] => "declares the join to the subscription the charge is for, which is absent for a one-time checkout",
    [ "app/models/charge.rb", "scope :for_account", "list" ] => "resolves one account's charges by `account_id`, the tenancy key the receipt route reads through",
    [ "app/services/webhooks/charges/recorder.rb", "find_customer", "read" ] => "resolves the cafaye customer a payment is for, by cafaye id or by processor id",
    [ "app/services/webhooks/charges/recorder.rb", "resolved_subscription", "read" ] => "resolves the subscription a payment is for, by the processor's subscription id",
    [ "app/services/webhooks/charges/recorder.rb", "record", "write" ] => "writes the charge a settled payment is the receipt for",
    [ "app/controllers/v1/charges_controller.rb", "show", "read" ] => "resolves a charge by its uuid inside `for_account`; another account's is a 404",

    # --- the recipient fact: the payment payload's one lookup (billing-event-payloads-01)
    # The payment events carry the customer's billing email because the fleet's
    # consumer cannot read it anywhere else, and this is the read that fact costs:
    # one indexed lookup on `customers.processor_customer_id` (unique, billing-13),
    # per payment event. It is the same lookup the recorder's `find_customer` makes
    # for the charge, made here for the event — a failed payment records no charge,
    # so the recorder's resolution cannot be the one the event relies on.
    [ "app/services/webhooks/stripe_events.rb", "recipient_email", "read" ] => "resolves the cafaye customer a payment is for, by the processor's customer id, for the recipient fact on the event",

    # --- the keyset every list goes through ----------------------------------
    [ "app/controllers/concerns/cursor_paging.rb", "apply_cursor", "list" ] => "applies a client-supplied keyset to a relation the caller chose",

    # --- the two declared joins, counted because an association is a query ----
    [ "app/models/subscription.rb", "belongs_to :customer", "read" ] => "declares the join to the account-scoped customer row",
    [ "app/models/subscription.rb", "belongs_to :plan", "read" ] => "declares the join to the catalogue row the subscription is billed against",

    # --- the declared queries, for the same reason ---------------------------
    # Seven scopes on three tenant tables: **two carry an account**
    # (`Customer.for_account`, `Subscription.for_account`, both landed in billing-21)
    # and five do not.
    #
    # --- the two account scopes, which is where billing-21 put the scoping -----
    # The shape scoping arrives in is `scope :for_account, ->(id) { where(account_id: id) }`,
    # and these two are that shape. They are counted because a scope is a query — and
    # `Subscription#for_account` in particular is the query every row-addressed `/v1`
    # action reaches a subscription through, so a change to it moves the tenant
    # boundary of the whole surface and this matrix is where that shows up.
    [ "app/models/customer.rb", "scope :for_account", "list" ] => "resolves one account's customers by `owner_type: Account` and `owner_id`; a `User`-owned customer is in no account and is excluded",
    [ "app/models/subscription.rb", "scope :for_account", "list" ] => "resolves one account's subscriptions by `account_id`, which is the tenancy key every row-addressed action reads through",

    # --- the five scopes that carry no account ---------------------------------
    # Status and publication predicates. All seven scopes are counted, because a scope
    # is a query and the two above are the shape these five would take if they were
    # scoped; leaving the category out of the enumeration is how the enumeration stops
    # being one.
    [ "app/models/subscription.rb", "scope :live", "list" ] => "resolves a subscription's live rows; carries no account and is not meant to",
    [ "app/models/subscription.rb", "scope :canceled", "list" ] => "resolves a subscription's canceled rows; carries no account and is not meant to",
    [ "app/models/outbox_event.rb", "scope :unpublished", "list" ] => "resolves unpublished outbox rows, whose payloads carry every account's events",
    [ "app/models/outbox_event.rb", "scope :oldest_first", "list" ] => "orders outbox rows for the publisher loop, which now exists: `Outbox::Relay` starts it when NATS_URL names a broker",
    [ "app/models/outbox_event.rb", "scope :for_processor_event", "list" ] => "resolves outbox rows by a processor event id, never by an account"
  }.freeze

  # Every file under `app/` that performs **no** data access, with the reason.
  #
  # Not a filter: an empty table would exit 0 having checked nothing, and a new
  # file that touches no row would join the surface without anybody saying so.
  # Two assertions below hold this closed in both directions.
  NO_DATA_ACCESS = {
    "app/controllers/application_controller.rb" => "assembles the shared response concerns; it queries nothing",
    # The four files billing-21 added. None reads a row: the concern decides whether
    # a request may proceed at all, the verifier reads a **signature and a key set**,
    # and the principal is a value object. Naming them here is what keeps the list
    # closed — a new file under `app/` that queries nothing has to say so, and this
    # one did.
    "app/controllers/concerns/authenticates_principal.rb" => "the `/v1` boundary: it reads a bearer token and renders a refusal, and it reaches no tenant row on either path",
    "app/lib/principal.rb" => "the verified caller as a value; it holds an account id and reads no model",
    "app/services/identity.rb" => "the identity namespace and its three refusal classes; it holds no query",
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
    "app/lib/parameter_error.rb" => "the error a bad query parameter raises; it holds no query",
    "app/lib/problem.rb" => "the problem vocabulary, a frozen table of codes and no model access",
    "app/mailers/application_mailer.rb" => "the abstract base class; it declares no query",
    "app/models/application_record.rb" => "the abstract base class; it declares no scope",
    "app/models/idempotency_key.rb" => "keyed on the request's own idempotency key, which is a client's, not an account's. Its `scope :expired` is a ttl and touches no tenant row, which is why a scope on a non-tenant model is not counted.",
    "app/models/money.rb" => "the money primitive; it reads no model",
    "app/models/processor_webhook.rb" => "the receipt model; its one write is `ingest`, addressed by the processor's event id",
    "app/services/processor.rb" => "the processor namespace; it declares no query",
    "app/services/processor/stripe_client.rb" => "builds and sends the three processor requests; the row each acts on was resolved by the caller",
    # The file the fake-client packet added when `pay` left. It holds no query:
    # the answer it builds is `ProcessorSubscription` — a frozen value object,
    # not the model. Naming the file here is what keeps the list closed for the
    # next value object somebody constructs in `app/`, and the reason is
    # written out because "the scanner misfires" is a reason about a tool, not
    # a reason about this file. The name is not decoration either: `Subscription`
    # would shadow the model for every reader, which is the exact confusion
    # this service's Charge-versus-processor's-charge distinction exists to
    # prevent.
    "app/services/processor/fake_client.rb" => "answers a checkout with a value object; the value it constructs is `Processor::FakeClient::ProcessorSubscription`, not the `subscriptions` table, and it reads and writes no model at all",
    "app/services/subscriptions.rb" => "the subscriptions namespace; it declares no query",
    "app/services/subscriptions/plan_change.rb" => "compares two prices and decides timing; pure, no model access",
    "app/services/subscriptions/state_machine.rb" => "a from-status and a to-status in, an answer out; pure, no model access",
    "app/services/webhooks.rb" => "the webhooks namespace; it declares no query",
    # The two files the checkout packet added. The namespace file holds no query —
    # it is a module and a comment, and saying so is what keeps the list closed —
    # and every read and write the checkout path performs is in `Session`, whose
    # accesses are classified above rather than excluded from the enumeration.
    "app/services/checkout.rb" => "the checkout namespace; it declares no query",
    "app/services/webhooks/emission.rb" => "the value object a handler returns; it holds no query",
    # The three files the outbox publisher packet added. None of them queries a
    # tenant model here: the namespace is a module and its refusal classes, the
    # transport speaks a broker protocol and holds no model, and the loop's claim
    # and mark are the shared gem's SQL over `outbox_events` — the one table with
    # no account column to scope by, already classified above through its scopes.
    # Naming them is what keeps the list closed, and the reason is written out
    # because "the loop touches no row" would be false if the gem were inlined.
    "app/services/outbox.rb" => "the outbox namespace and its configuration refusal; it declares no query",
    "app/services/outbox/nats_publisher.rb" => "puts an envelope on the broker and waits for the ack; it holds no model and the payload is never read back out of it",
    "app/services/outbox/relay.rb" => "the loop and the boot condition: it resolves the shared gem's publisher over the outbox connection pool, and the claim and the marks are the gem's SQL over the account-less outbox table, not this file's"
    # `app/services/webhooks/stripe_events.rb` was on this list until
    # billing-event-payloads-01: the recipient fact's one lookup
    # (`recipient_email`, classified in DATA_ACCESSES above) is a row read, and a
    # file that performs one does not belong among the files that perform none.
    # The list is closed in both directions, so the entry is dropped rather than
    # reworded — the access has an entry point and a scope now, which is what the
    # exclusion was standing in for.
  }.freeze

  # --- the derivation --------------------------------------------------------

  # A data access found in the source: the file, the method, the kind, and the
  # expression that performed it. One scan of `app/`, so the tables above are
  # compared against the code rather than against a list somebody has to remember
  # to update.
  Access = Data.define(:path, :method, :kind, :expression) do
    # The `(path, method)` pair — the unit a reader thinks in.
    def site = [ path, method ]

    # The full key, kind included, because one method can perform two kinds.
    def key = [ path, method, kind ]

    def to_s = "#{path}##{method} (#{expression}, #{kind})"
  end

  # The expressions that perform a data access, per kind. A table rather than one
  # large regexp, so a new shape is a new entry a reader can see.
  #
  # `assign_attributes` is in the list because it is a write to a row that already
  # exists and nothing else in it says so: a `find` followed by a `save` is two
  # accesses, and only one of them is a resolution.
  #
  # `scope.where` is `CursorPaging#apply_cursor` and nothing else in the
  # repository, written out rather than matched as a bare `where` because a bare
  # `where` would also match a hash condition on a model scope, which is not a
  # separate entry point — it is a predicate on one already listed.
  #
  # `belongs_to` is counted as a **declared** join. The two in `Subscription` and
  # the two in `Charge` are the only ones, and the method name is the whole
  # declaration because a `belongs_to` is not inside a `def`.
  #
  # `scope` is counted for the same reason, and is the shape account scoping is
  # most likely to arrive in — `scope :for_account, ->(id) { where(account_id: id) }`
  # — so a scope nobody classified has to fail here rather than becoming the first
  # account-scoped query in the service with no entry point and no negative test.
  #
  # Matched on the **declaration** rather than on the body, and that is not a
  # simplification. `scope :oldest_first, -> { order(:created_at, :id) }` has no
  # `where` in it at all, and `scope :for_processor_event` puts its `where` on the
  # line *after* the arrow — so a pattern looking for a body would find two of the
  # five and miss both, in the same way, on the same line. Every scope returns a
  # relation and every relation is a collection read, so `list` is the correct kind
  # for all of them and no body needs reading.
  #
  # **`for_account` is in the list, and its kind depends on what it is chained to.**
  #
  # billing-21 made it the shape every account-scoped query takes, so a scanner that
  # only knew `find` and `all` would have watched all five `/v1` customer and
  # subscription reads **disappear from the enumeration** the day the code was fixed
  # — and a matrix whose count falls when the boundary lands is a matrix that stops
  # being able to notice the boundary moving again.
  #
  # Two entries rather than one, and the order matters because the scan breaks on the
  # first pattern a line matches:
  #
  #   * `Customer.for_account(id).find(...)` is a **read** — one row, resolved inside
  #     a scope. This is what every row-addressed action on `/v1` does.
  #   * `Customer.for_account(id)` on its own is a **list** — a relation, which is
  #     what `paginate` is handed.
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
    # The projection is a READ of the processor — it asks for a figure and
    # changes nothing — so it is classified as one, and the pattern that
    # otherwise catches every processor call is extended to catch it.
    [ "read",   /\bprocessor\.upcoming_invoice\(/ ]
  ].freeze

  # The patterns that only count **on a tenant model**. `scope` is one of them,
  # and the reason is `IdempotencyKey`: it has a `scope :expired`, and counting it
  # would put a fourth model in the tenant-data set and quietly contradict the
  # three-model pin above — a model that touches no tenant row is not tenant data
  # because it declares a query.
  #
  # So the check is on the **declaring class**, read out of the file, rather than
  # on the file's path. A path list would have to be edited every time a model
  # moved, and the one time somebody forgets is the one that matters.
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
      # One pass per file, tracking the innermost `def` seen so far, so each match
      # is attributed to the method a reader would name. A class-level
      # `create!` lands under the class name; a `belongs_to`, which is not inside
      # a `def`, lands under its own declaration.
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

      # The patterns that apply to this file. A declaration is only counted when
      # the class declaring it is one of the tenant models, so
      # `IdempotencyKey#scope :expired` is not a tenant-data access and
      # `Subscription#belongs_to :customer` is.
      #
      # `declaring_model` is the check, not the path: `idempotency_key.rb` declares
      # `class IdempotencyKey < ApplicationRecord`, which is not in `TENANT_MODELS`,
      # so its scope drops out — and `IdempotencyKey` has a comment saying in as
      # many words that it is keyed on the client's own idempotency key and not on
      # an account. Counting it would put a fourth model in the tenant-data set and
      # quietly contradict the three-model pin.
      def patterns_for(source)
        declares_tenant_query = source.match?(/\b(?:belongs_to\s+:|scope\s+:[a-z_]+,\s*->)/)
        return ACCESS_EXPRESSIONS if declares_tenant_query && declared_tenant_model?(source)

        ACCESS_EXPRESSIONS - TENANT_MODEL_ONLY_EXPRESSIONS
      end

      def declared_tenant_model?(source)
        (TENANT_MODELS + PAYLOAD_TENANT_MODELS).include?(declaring_model(source))
      end

      # The ApplicationRecord subclass this file declares, or nil. Read from the
      # source rather than inferred from the path, so moving a model between
      # directories does not change what it is counted as.
      def declaring_model(source)
        source[/^class\s+([A-Z][A-Za-z0-9_]*)\s*<\s*ApplicationRecord/, 1]
      end
  end

  # --- the two directions, for the data accesses -----------------------------

  # The direction that finds things. A data access in `app/` that no table claims
  # is an entry point whose scope nobody decided, and the next person to read the
  # diff will not notice it either.
  test "every data access in app is an account-scoped entry point" do
    unclassified = self.class.accesses.reject { |access| DATA_ACCESSES.key?(access.key) || NO_DATA_ACCESS.key?(access.path) }

    assert_empty unclassified.map(&:to_s),
      "these data accesses are in app/ and in no table. Decide whether each is " \
      "account-scoped: add it to DATA_ACCESSES with its kind and what it touches, or " \
      "name the file in NO_DATA_ACCESS with the reason it is not."
  end

  # The other direction, and the one that keeps the table from rotting. A row for
  # a method that has gone away excludes nothing today and will exclude whatever
  # is added at that method next, which is why a stale row fails.
  test "every entry point this matrix classifies is one the source still has" do
    assert_empty classified_sites - self.class.accesses.map(&:site).uniq,
      "these entry points are classified for a method that no longer exists. A method " \
      "that went away takes its scope classification with it."
  end

  # The third direction, and the one that catches the interesting edit: a method
  # that already exists and has **grown an access of a kind this table does not
  # claim for it**. `apply` building a row and then writing to it is the case the
  # kind-in-the-key exists for; without this check, adding a `find` to a
  # classified `list` method would be silently swallowed.
  test "every data access's kind is one this matrix claims for that method" do
    # `DATA_ACCESSES.keys`, not the hash itself: `group_by` over a Hash yields
    # `[key, value]` pairs, and destructuring a three-element key out of a
    # two-element pair silently files every row under `path = [path, method, kind]`
    # and leaves the lookup empty — which fails every access at once and looks
    # like a total absence of classification rather than a broken predicate.
    claimed = DATA_ACCESSES.keys.group_by { |path, method, _kind| [ path, method ] }
      .transform_values { |rows| rows.map { |(_path, _method, kind)| kind } }

    unclaimed = self.class.accesses.reject { |access| claimed.fetch(access.site, []).include?(access.kind) }

    assert_empty unclaimed.map(&:to_s),
      "these accesses are in a method this matrix classifies, but at a kind it does not " \
      "claim for it. A method that grew an access of another kind needs its own row."
  end

  # --- the counts the report quotes ------------------------------------------

  # **45 data accesses, in 42 methods, filed under 43 keys.** All three numbers
  # are asserted, and neither gap between them is a rounding of the one above.
  #
  # billing-13's 33 became 35 and **both of the new ones are the account scopes
  # themselves** — `Customer.for_account` and `Subscription.for_account`, declared on
  # the two models. They are counted here for the reason the five existing scopes are:
  # a scope is a query, and `Subscription#for_account` is the query every
  # row-addressed `/v1` action reaches a subscription through, so it is an entry
  # point whose scope somebody decided rather than one that arrived by nobody writing
  # it down. Both are `list`: a scope returns a relation, and a relation is a
  # collection read whatever it is later chained to.
  #
  # Nothing was **removed** in billing-21, which is the more interesting half: the five
  # `/v1` customer and subscription rows were re-expressed from `Customer.all` and
  # `Subscription.find` into `for_account(...)`, and the scanner's `ACCESS_EXPRESSIONS`
  # gained the two patterns that keep them in the enumeration. Without those patterns
  # this count would have fallen by five on the day the boundary landed, and a matrix
  # whose total drops when the tenant boundary is fixed is a matrix that can no longer
  # notice it moving again.
  #
  # The charges packet's 36 became 44, and the eight are the whole of that surface:
  # `Charge`'s two joins and its account scope (declarations, counted for the reason
  # the nine above are), the recorder's three lookups and its write, and the receipt
  # route's read. **The scanner had to learn `Charge` to see any of them** — its
  # patterns name the tenant models explicitly, so a fourth tenant model was
  # invisible until it was added to the alternation, and the matrix's first draft
  # of this packet shipped a recorder whose `Customer.find_by` and
  # `Subscription.find_by` were unclassified accesses in `app/`. A data access
  # the enumeration cannot see is the failure this file exists to prevent.
  #
  # Three methods now do two things, for three different reasons:
  #
  #   * `Subscriptions::Lifecycle#customer` performs **two lookups** —
  #     `Customer.find_by(id: cafaye_customer_id)` and
  #     `Customer.find_by(processor_customer_id:)` — under one description,
  #     because one row can be found by either identifier and a delivery may
  #     carry only one.
  #   * `Webhooks::Charges::Recorder#find_customer` performs the same **two
  #     lookups** under one description, for the same reason: a payment may
  #     carry a cafaye id or a processor id and never both.
  #   * `Subscriptions::Lifecycle#apply` builds a row that did not exist **and**
  #     writes to the one that did, so it has two keys. So there are more keys
  #     than methods.
  #
  # A single number would have hidden all three, and all three are the shape of the code.
  #
  # billing-event-payloads-01's 44 became 45, and the new one is the recipient
  # fact's lookup: `StripeEvents.recipient_email` resolves the cafaye customer a
  # payment is for, by the processor's customer id, so the payment events can
  # carry the customer's billing email. It is the same lookup the recorder's
  # `find_customer` makes for the charge, made for the event — a failed payment
  # records no charge, so the recorder's resolution cannot be the one the event
  # relies on. The file left `NO_DATA_ACCESS` the same day: a file that performs
  # a read does not belong among the files that perform none.
  test "there are 48 account-scoped data accesses in 45 methods, filed under 46 keys" do
    assert_equal 48, self.class.accesses.size
    assert_equal 45, classified_sites.size
    assert_equal 46, DATA_ACCESSES.size

    assert_equal 2, self.class.accesses.size - DATA_ACCESSES.size,
      "the gap between accesses and keys has changed. It is 2 because `Lifecycle#customer` " \
      "and `Recorder#find_customer` each do two lookups under one description; a different " \
      "number means a method is doing something the table no longer describes."

    assert_equal 1, DATA_ACCESSES.size - classified_sites.size,
      "the gap between keys and methods has changed. It is 1 because `Lifecycle#apply` " \
      "both creates and writes; a different number means a method is doing something the " \
      "table no longer describes."
  end

  # The per-operation breakdown, tallied from **the source** rather than from the
  # table, so a mislabelled row cannot make the headline agree with itself. The
  # zero kinds are filled in explicitly because `tally` omits an absent key, and
  # a breakdown that quietly lost `delete` is the one breakdown this file exists
  # to keep honest.
  test "the data-access breakdown is read 22, list 12, write 9, update 5, delete 0" do
    assert_equal({ "read" => 22, "list" => 12, "write" => 9, "update" => 5, "delete" => 0 }, breakdown(self.class.accesses.map(&:kind)))
  end

  # **15 account-scoped routes**, derived from the router, in the same four kinds.
  # This is the caller-facing count, and unlike the one above it does not change
  # when a helper is extracted.
  test "there are 17 account-scoped routes, and the router serves exactly them plus the webhook" do
    assert_equal 17, ACCOUNT_SCOPED_ROUTES.size
    assert_equal served_routes.to_set,
                 (ACCOUNT_SCOPED_ROUTES.keys + NOT_ACCOUNT_SCOPED_ROUTES.keys).to_set
  end

  # The two route tables must not both claim the same operation. Where they
  # overlap, neither half can be right.
  test "no route is both account-scoped and not" do
    assert_empty (ACCOUNT_SCOPED_ROUTES.keys & NOT_ACCOUNT_SCOPED_ROUTES.keys).map { |method, path| "#{method} #{path}" }
  end

  test "every route that is not account-scoped says why it is not" do
    unexplained = NOT_ACCOUNT_SCOPED_ROUTES.select { |(_operation), reason| reason.to_s.strip.empty? }

    assert_empty unexplained.keys.map { |method, path| "#{method} #{path}" },
      "these routes are excluded with no reason"
  end

  test "the route breakdown is read 6, list 3, write 4, update 4, delete 0" do
    assert_equal({ "read" => 6, "list" => 3, "write" => 4, "update" => 4, "delete" => 0 },
                 breakdown(ACCOUNT_SCOPED_ROUTES.values.map(&:first)))
  end

  # The two layers side by side, so a reader has one place to check that the
  # packet's headline is two separately-asserted numbers and not one sum that
  # double-counts a route against the method that serves it.
  test "the two layers are counted separately, because a route and the method that serves it overlap" do
    assert_equal 17, ACCOUNT_SCOPED_ROUTES.size
    assert_equal 48, self.class.accesses.size
    refute_equal ACCOUNT_SCOPED_ROUTES.size, self.class.accesses.size,
      "the two layers have converged, which means one of them is counting the other's rows"
  end

  # --- delete is zero, and that is a fact about the service ------------------

  # Nothing in `app/` destroys or deletes a row, so there is no delete to scope
  # and none to forget. A service that scopes its reads and forgets its deletes is
  # the common shape, and this is the assertion that says the shape is not this
  # one *today* — in the same commit a destroy is added, this fails and the new
  # access has to be scoped.
  #
  # The route half is the same fact from the other side: the router serves no
  # `DELETE` under `/v1` at all.
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

  # --- the claims the tables make about themselves ---------------------------

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

  # The exclusion list is closed in **both** directions. A new file under `app/`
  # that performs no data access and is not named here fails, which is what makes
  # the scan total; and a file named as performing none that grows one fails the
  # other way, which stops the list becoming a place to hide an access.
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

  # The tenant-data set is the same four models the contract matrix pins, plus the
  # one model that carries an account in its payload without having the column.
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

    # A tally with every kind present, including the ones with no rows. `tally`
    # omits an absent key, and the omitted key is the one this file most needs to
    # state out loud.
    def breakdown(kinds)
      KINDS.index_with { |kind| kinds.count(kind) }
    end

    # `(method, router path)` for every `/v1` operation, in the router's spelling.
    def served_routes
      @served_routes ||= Rails.application.routes.routes.flat_map { |route|
        path = route.path.spec.to_s.sub("(.:format)", "")
        next [] unless path.start_with?("/v1")

        methods_for(route).map { |method| [ method, path ] }
      }.uniq
    end

    # `via: :all` draws a route with no verb constraint, which answers every
    # method. The same expansion `contract/tenant_isolation_matrix_test.rb` uses,
    # for the same reason: one vocabulary for "what the router serves".
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
