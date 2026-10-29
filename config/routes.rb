Rails.application.routes.draw do
  get "healthz" => "health#show", as: :healthz
  get "readyz" => "health#ready", as: :readyz

  get "up" => "rails/health#show", as: :rails_health_check

  scope "/v1", module: :v1 do
    get "customers", to: "customers#index"
    post "customers", to: "customers#create"
    get "customers/:id", to: "customers#show"
    patch "customers/:id", to: "customers#update"

    get "plans", to: "plans#index"
    post "plans", to: "plans#create"
    get "plans/:slug", to: "plans#show"
    patch "plans/:id", to: "plans#update"

    get "subscriptions", to: "subscriptions#index"
    post "subscriptions", to: "subscriptions#create"
    get "subscriptions/:id", to: "subscriptions#show"
    post "subscriptions/:id/cancel", to: "subscriptions#cancel"
    post "subscriptions/:id/change_plan", to: "subscriptions#change_plan"
    get "subscriptions/:id/entitlements", to: "subscriptions#entitlements"
    get "subscriptions/:id/upcoming_invoice", to: "subscriptions#upcoming_invoice"
    post "subscriptions/:id/payment_method", to: "subscriptions#payment_method"

    get "charges", to: "charges#index"
    get "charges/:id", to: "charges#show"

    post "checkouts", to: "checkouts#create"

    get "token_wallet", to: "token_wallets#show"
    get "token_wallet/entries", to: "token_wallets#entries"
    post "token_wallet/grant", to: "token_wallets#grant"
    post "token_wallet/deduct", to: "token_wallets#deduct"
    post "token_wallet/adjust", to: "token_wallets#adjust"
  end

  post "v1/webhooks/stripe", to: "webhooks/stripe#create", as: :stripe_webhook

  match "/404", to: "errors#not_found", via: :all, as: :not_found_page
  match "/422", to: "errors#unprocessable_entity", via: :all, as: :unprocessable_entity_page
  match "/500", to: "errors#internal_server_error", via: :all, as: :internal_server_error_page
  match "/503", to: "errors#service_unavailable", via: :all, as: :service_unavailable_page
end
