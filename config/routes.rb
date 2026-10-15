Rails.application.routes.draw do
  # Health probes used by Docker/Kamal, the load balancer and uptime monitors.
  # Infrastructure, not contract surface: they are not in `cafaye.yml`'s
  # `exposes`, they take no query parameters, and no client parses them.
  get "healthz" => "health#show", as: :healthz
  get "readyz" => "health#ready", as: :readyz

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The API. `/v1` is the API version and changes only for a breaking change,
  # which means a new prefix alongside this one — never this one mutated in
  # place (core's openapi-conventions.md).
  scope "/v1", module: :v1 do
    # Spelled out rather than generated, for one reason: `resources`' `update`
    # draws **two** routes for one action — `PATCH` and `PUT` — and this
    # service's update is a partial update. `CustomerUpdate` in the document says
    # every field is optional and an absent field is left alone, and it closes
    # the object: `owner` and `processor` are the key the uniqueness rule is built
    # on, are not updatable at all, and moving a customer is a delete and a
    # create. There is no whole-resource replacement here to put behind a `PUT`,
    # so the route stops being drawn. It was served and in no document; see
    # `test/contract/http_surface_contract_test.rb` and CHANGELOG.
    get "customers", to: "customers#index"
    post "customers", to: "customers#create"
    get "customers/:id", to: "customers#show"
    patch "customers/:id", to: "customers#update"

    # `plans` is spelled out rather than generated, because the two lookups are
    # addressed differently on purpose: read by slug, write by id. See
    # V1::PlansController.
    get "plans", to: "plans#index"
    post "plans", to: "plans#create"
    get "plans/:slug", to: "plans#show"
    patch "plans/:id", to: "plans#update"

    # Spelled out rather than generated for the same reason as `plans`, and one
    # more: three of these are sub-resources with their own verbs, and `resources`
    # would either invent paths for them or need a second declaration that says the
    # same thing twice. `cancel` and `change_plan` are POSTs rather than DELETEs on
    # purpose — cancelling at the end of the period is not a deletion, and a DELETE
    # that does not delete is a lie about the method.
    get "subscriptions", to: "subscriptions#index"
    post "subscriptions", to: "subscriptions#create"
    get "subscriptions/:id", to: "subscriptions#show"
    post "subscriptions/:id/cancel", to: "subscriptions#cancel"
    post "subscriptions/:id/change_plan", to: "subscriptions#change_plan"
    get "subscriptions/:id/entitlements", to: "subscriptions#entitlements"
    # The processor's projection of the next invoice for one of this account's
    # subscriptions, resolved through the same scoped `subscription_record` as
    # every other row-addressed action. A read that asks the processor a
    # question rather than telling it to do something.
    get "subscriptions/:id/upcoming_invoice", to: "subscriptions#upcoming_invoice"

    # Charges: what a customer was charged, for the receipt. Read by id, scoped
    # by the token's account — a cross-tenant read is a 404, the same answer a
    # uuid naming nothing gets.
    get "charges/:id", to: "charges#show"

    # The fake-processor checkout: a checkout that completes in the request. The
    # production door is `POST /v1/subscriptions` above, which asks Stripe for a
    # hosted session and writes nothing; this one exists for the developer, the
    # demo, and a CI suite that holds no Stripe key, and it answers 404 unless
    # `BILLING_FAKE_PROCESSOR_ENABLED` is set. See V1::CheckoutsController.
    post "checkouts", to: "checkouts#create"
  end

  # Processor webhooks. Each processor gets its own path, its own signature
  # scheme and its own controller: a shared endpoint would need a dispatcher that
  # branches on the path anyway, and one processor's parsing bug would end up
  # sitting next to another's verification code.
  #
  # Declared outside the `scope "/v1", module: :v1` above on purpose. The version
  # prefix is the same, but the controller is not part of the `V1` module and does
  # not share its base: the `/v1` API is a cafaye client surface and this is a
  # processor surface, authenticated by signature rather than by token, and the two
  # must not grow a shared superclass that assumes both.
  #
  # It is declared in `openapi/v1.yaml`, which the manifest's `exposes.api`
  # points at.
  post "v1/webhooks/stripe", to: "webhooks/stripe#create", as: :stripe_webhook

  # Where `config.exceptions_app = routes` sends a response Rails raised rather
  # than one a controller rendered, so a 404 on an unknown path and a 500 on an
  # unhandled bug are problem+json too.
  match "/404", to: "errors#not_found", via: :all, as: :not_found_page
  match "/422", to: "errors#unprocessable_entity", via: :all, as: :unprocessable_entity_page
  match "/500", to: "errors#internal_server_error", via: :all, as: :internal_server_error_page
  match "/503", to: "errors#service_unavailable", via: :all, as: :service_unavailable_page
end
