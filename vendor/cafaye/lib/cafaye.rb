# frozen_string_literal: true

require "cafaye/version"
require "cafaye/errors"
require "cafaye/configuration"
require "cafaye/principal"
require "cafaye/token"
require "cafaye/jwks/key_set"
require "cafaye/jwks/transport"
require "cafaye/jwks/fetcher"
require "cafaye/jwks/cache"
require "cafaye/token_verifier"
require "cafaye/outbox"
require "cafaye/railtie" if defined?(::Rails::Railtie)

# The shared Ruby library every cafaye Ruby service depends on, so that no
# service hand-rolls token verification or the outbox insert.
#
# Two things, both of which are a security incident waiting to be hand-written:
#
#   Cafaye::TokenVerifier — RS256 bearer tokens verified against identity's
#     published JWKS, with the algorithm allowlisted, the key set cached, and
#     the result frozen and explicit. Nothing it returns can carry the token, a
#     claim, or a key.
#
#   Cafaye::Outbox — core's event envelope, written into a Postgres outbox
#     inside the caller's own transaction, plus the loop that moves committed
#     rows to a transport.
#
# Both are inert until configured. Requiring this file installs nothing, opens
# nothing and connects to nothing, so an unconfigured service that has not
# called `Cafaye.configure` gets no error at boot and no behaviour at runtime —
# it is a library, not a framework that assumes it owns the process.
module Cafaye
  class << self
    # The process-wide configuration. A fresh, empty one until `configure` is
    # called, which is what "inert until configured" means: an empty
    # configuration is not a default configuration, it is the absence of one.
    def config
      @config ||= Configuration.new
    end

    # Yields the configuration for the block, or replaces it with the argument.
    #
    #   Cafaye.configure do |config|
    #     config.service_name = "billing"
    #     config.identity_issuer = "https://identity.cafaye.com"
    #     config.audience = "cafaye-services"
    #   end
    #
    # Mutating in place rather than replacing, so an initializer that sets two of
    # the five settings and a second initializer that sets another do not silently
    # discard each other.
    def configure
      yield config if block_given?
      config
    end

    # The verifier the process uses.
    #
    # Memoised so there is one key-set cache per process: two verifiers would
    # fetch the key set twice and could disagree about whether a rotation has
    # happened, which is the one thing a key cache exists to prevent.
    def token_verifier
      @token_verifier ||= token_verifier_for(config)
    end

    # The outbox writer the process uses. See `outbox_for` for why this raises
    # rather than returning a lazy default.
    def outbox
      @outbox ||= outbox_for(config)
    end

    # Whether the process has been configured. A caller that wants to know
    # whether it may use this library asks here rather than rescuing from
    # `Cafaye.outbox`.
    def configured?
      config.configured?
    end

    def token_verifier_for(configuration)
      TokenVerifier.new(**configuration.to_token_verifier_options)
    end

    def outbox_for(configuration)
      if configuration.service_name.nil? || configuration.service_name.to_s.empty?
        raise Errors::ConfigurationError,
              "Cafaye.configure has not been called: an outbox writer needs a service_name, " \
              "which is the `source` on every envelope it writes"
      end

      unless Cafaye::Outbox::Envelope::SOURCE_PATTERN.match?(configuration.service_name.to_s)
        raise Errors::ConfigurationError,
              "service_name must be a cafaye service name, got #{configuration.service_name.inspect}"
      end

      Outbox::Writer.new(
        connection: configuration.outbox_connection || default_outbox_connection,
        service_name: configuration.service_name,
        clock: configuration.clock,
        payload_validators: configuration.payload_validators
      )
    end

    # The library's logger. Every log line it writes goes here, and the canary
    # test asserts over this sink, so a caller that swaps it in a test is not
    # exempt from the assertion.
    def logger
      @logger ||= default_logger
    end

    attr_writer :logger

    # The default sink is Ruby's stdlib logger on $stderr at WARN and above.
    #
    # Two reasons it is not a Rails logger: this gem must load in a non-Rails
    # service and in a plain script, and a library that reaches for its host's
    # logging framework at load time is a library that cannot be loaded before
    # the framework is configured. The Railtie points it at `Rails.logger` once
    # the host app is configured, which is the one moment it is safe to.
    #
    # Nothing at INFO or below is written by default, and there is nothing to
    # turn on. The library logs refusals and key-set failures and nothing else,
    # because the only two things a security library can usefully log are "a
    # request was refused, and why in the library's own vocabulary" and "I could
    # not reach a dependency". Everything a token carries is a secret by
    # construction, so there is no level at which it would be safe to print.
    def default_logger
      require "logger"
      logger = Logger.new($stderr)
      logger.level = Logger::WARN
      logger.formatter = ->(severity, _time, _progname, message) { "#{severity} cafaye: #{message}\n" }
      logger
    end

    # Test and development seam. `bin/prime` runs the suite in one process, and
    # a suite that cannot see the library's log output cannot assert on it.
    def reset!
      @config = nil
      @token_verifier = nil
      @outbox = nil
      @logger = nil
    end

    private

    # Active Record's leased connection, which is the only answer that can enlist
    # the insert in the caller's transaction. Required rather than optional: a
    # second connection built from the same database config is a different
    # session, is not enlisted, and would commit the event on its own — the exact
    # failure the outbox exists to prevent, wearing the costume of a correct
    # implementation. A non-Rails service sets `outbox_connection` explicitly.
    def default_outbox_connection
      pool = begin
        ::ActiveRecord::Base.connection_pool
      rescue ::ActiveRecord::ConnectionNotDefined
        nil
      end

      if pool.nil?
        raise Errors::ConfigurationError,
              "outbox_connection is required: there is no Active Record connection to enlist in, " \
              "and a second connection would not roll back with the caller's transaction"
      end

      Outbox::ActiveRecordConnection.for(::ActiveRecord::Base)
    end
  end
end
