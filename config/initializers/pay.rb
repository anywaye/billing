# `pay`'s configuration, and every line of it is a refusal.
#
# The gem is here for **FakeProcessor**: a processor whose "API" is the database,
# which is what makes a checkout path testable end to end with no network, no keys
# and no Stripe account. Nothing in this build talks to a live processor, so the
# gem's default posture is wrong here in three separate ways and each one is
# turned off by name rather than left to be discovered in production.
#
#   * `enabled_processors` is **empty**. The default is Stripe, Braintree, Paddle
#     and Lemon Squeezy, and `pay` runs `Pay::Stripe.configure_webhooks` in a
#     `before_initialize` for every one that is enabled — so leaving the default
#     in place means booting this service tries to register webhooks with four
#     processors, and needs four sets of credentials to do it. `pay`'s live
#     processors are a later packet.
#   * `automount_routes` is **false**. The engine mounts itself at `/pay`, and
#     every route the router serves is a client operation this service has
#     declared in `openapi/v1.yaml` and classified in
#     `test/contract/http_surface_contract_test.rb`. A mounted engine is a whole
#     undocumented surface appearing under a prefix — the same class of problem as
#     a `/internal` nobody argued about. Checkout is a service call here, not a
#     hosted page: `Checkout::Session` is the entry point.
#   * `send_emails` is **false**. `pay` ships `Pay::UserMailer` and would render
#     one from inside a processor callback. Transactional mail is courier's
#     (`AGENTS.md`, Events), and a mailer appearing in this process is a second
#     answer to "who tells the customer they are now paying".
#
# `model_parent_class` is the other line that is not a refusal: `pay` parents its
# tables on `ActiveRecord::Base` by default, and this repository parents every
# model on `ApplicationRecord`. Naming it keeps the two conventions one.
Pay.setup do |config|
  config.model_parent_class = "ApplicationRecord"
  config.automount_routes = false
  config.enabled_processors = [].freeze
  config.send_emails = false
  config.application_name = "cafaye billing"
end
