# frozen_string_literal: true

require "rails/railtie"
require "cafaye/configuration"
require "cafaye/generators/outbox_generator"

module Cafaye
  # Installs both halves of this gem into a host application.
  #
  # A host app gets the outbox writer and the token verifier by adding a gem and
  # a config block, rather than by copying code:
  #
  #   # config/application.rb
  #   config.cafaye.service_name = "billing"
  #   config.cafaye.identity_issuer = "https://identity.cafaye.com"
  #   config.cafaye.audience = "cafaye-services"
  #
  #   # app/models/customer.rb
  #   after_create :publish_created
  #   def publish_created
  #     Cafaye.outbox.publish!(type: "billing.customer.created", subject: id, data: { customer_id: id })
  #   end
  #
  # ## Inert until configured
  #
  # This railtie does **nothing at all** until `Cafaye.config` is complete. It
  # installs no middleware, opens no connection, reads no environment variable
  # and raises nothing. An app that has the gem on its Gemfile and has not asked
  # for anything yet boots exactly as it would without the gem.
  #
  # That is a decision, not an omission. `guard`'s AGENTS.md states the same rule
  # from the other side: an unconfigured library that raises at boot is a worse
  # failure than one that does nothing, because the second is visible in a log
  # line and the first takes the process down for a service that has not asked
  # for anything.
  #
  # ## Misconfiguration is a boot failure
  #
  # Once the configuration *is* complete, it is validated at boot by building the
  # verifier. An issuer with no audience, a service name that is not a service
  # name, a plain-http issuer off loopback — all of them are boot failures here
  # rather than 503s on every request, because a typo nobody finds at boot is a
  # typo that is still there next week.
  class Railtie < ::Rails::Railtie
    # The namespace a host writes into. An `OrderedOptions` rather than a plain
    # hash so `config.cafaye.anything = x` is not a `NoMethodError` at boot in
    # an app that has misremembered a setting name — it is an unknown setting,
    # and `install!` reports it rather than raising on the typo itself.
    config.cafaye = ActiveSupport::OrderedOptions.new

    initializer "cafaye.install", after: :load_config_initializers do |app|
      Cafaye::Railtie.install!(Cafaye.config, logger: Cafaye::Railtie.host_logger(app))
    end

    class << self
      # Where a host app wants this library's refusals to go. `Rails.logger`,
      # found once, and only if it is actually there — a railtie that reached for
      # it during `require` would be reaching into a framework that has not been
      # configured yet, which is how a library ends up owning its host's boot.
      def host_logger(app)
        return nil unless app.respond_to?(:config) && app.config.respond_to?(:cafaye_logger)

        app.config.cafaye_logger
      end
      # @param config [Cafaye::Configuration]
      # @param logger [#warn, nil] where the library should log. `nil` leaves
      #   whatever is already there, so a host that set `Cafaye.logger` before
      #   the railtie ran keeps it.
      def install!(config, logger: nil)
        # `config.cafaye` is what a host wrote in an environment file, merged over
        # whatever an initializer set. It is reached through the railtie's own
        # configuration object, which `Rails::Railtie.config` resolves to via
        # `method_missing` on the railtie instance.
        config.merge_from(self.config.cafaye)

        # Nothing configured: inert. Not "partly configured" — nothing at all.
        return false unless config.any_settings?

        # Something configured but not enough. This is the case that must not be
        # silent: an app that set an issuer and no audience believes it verifies
        # tokens, and it does not. Naming the missing settings is the whole value
        # of raising here rather than on the first request.
        unless config.configured?
          raise Errors::ConfigurationError,
                "Cafaye is partly configured: missing #{config.missing_settings.join(', ')}"
        end

        # Validate, at boot. Building the verifier is the validation: its
        # constructor refuses an issuer with a path, a plain-http issuer off
        # loopback, a zero TTL, an empty audience, and a claim list that is
        # empty. Building the outbox writer refuses a service name that is not a
        # service name.
        build!(config)

        Cafaye.logger = logger if logger
        true
      end

      # Builds both halves. Separate from `install!` so a console or a test can
      # build them without the "was anything configured" question, and so the
      # memoisation is in one place.
      def build!(config)
        [ Cafaye.token_verifier_for(config), Cafaye.outbox_for(config) ]
      end

      def cafaye_config
        config.cafaye
      end
    end
  end
end
