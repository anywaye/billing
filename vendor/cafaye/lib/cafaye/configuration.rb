# frozen_string_literal: true

module Cafaye
  # Everything this library needs to know, in one object.
  #
  # It exists so a host app has exactly one place to configure, whether that is
  # an initializer calling `Cafaye.configure` or an environment file writing
  # `config.cafaye.service_name = "billing"`. Both write here.
  #
  # Nothing is validated on assignment. An unset setting is `nil` and stays
  # `nil`, and the configuration is validated when the verifier or the outbox is
  # *built* — which `Cafaye::Railtie.install!` does at boot, so a typo is a boot
  # failure rather than a 503 on every request.
  class Configuration
    # This service's namespace name. Also the `source` on every envelope it
    # writes and the first segment of every `type`.
    attr_accessor :service_name

    # identity's origin. Both the expected `iss` and the base the JWKS path is
    # appended to.
    attr_accessor :identity_issuer

    # The `client_id` every token must be addressed to.
    attr_accessor :audience

    # A key set served somewhere other than the issuer's own well-known path.
    attr_accessor :jwks_url

    attr_accessor :jwks_cache_ttl, :jwks_timeout, :unknown_kid_ttl, :min_refresh_interval, :leeway
    attr_accessor :account_claim, :scope_claims, :require_account

    # Where the outbox writes. `nil` means "whatever Active Record is using",
    # which is the only answer that can enlist in the caller's transaction; a
    # host that has no Active Record sets this to a `PG::Connection`.
    attr_accessor :outbox_connection

    # The library's logger. `nil` means "leave whatever is there", so a host
    # that set it before the railtie runs keeps it.
    attr_accessor :logger

    # A callable returning a `Time`. Injected so a host can test a rotated clock
    # and so this library's own suite never reads the wall clock.
    attr_accessor :clock

    # Per-event-type payload validators, keyed by event type. See
    # `Cafaye::Outbox::Writer`.
    attr_accessor :payload_validators

    def initialize
      @clock = -> { Time.now }
      @payload_validators = {}
    end

    # The three settings without which nothing can be built, and without which
    # nothing *should* be built.
    REQUIRED = %i[service_name identity_issuer audience].freeze

    # Everything else a host may set. A host that sets only one of these has still
    # made a configuration decision, and a boot failure naming the three it is
    # missing is more useful than silence.
    OPTIONAL = %i[jwks_url jwks_cache_ttl jwks_timeout unknown_kid_ttl min_refresh_interval
                  leeway account_claim scope_claims outbox_connection payload_validators].freeze

    # Whether this configuration is complete enough to build anything from.
    #
    # Deliberately not "whether anything is set": an app that has set only
    # `service_name` is not configured, and must not have a verifier or an outbox
    # built from it. A half-configured app with working verification is a worse
    # state than an unconfigured one, because the app believes it is protected.
    def configured?
      missing_settings.empty?
    end

    # Whether anything at all has been set. The difference between this and
    # `configured?` is the difference between a gem that does nothing and a gem
    # that refuses to boot: an app with the gem on its Gemfile and no config block
    # must be inert, and an app that set half the settings has made a mistake worth
    # naming.
    def any_settings?
      (REQUIRED + OPTIONAL).any? { |name| set?(public_send(name)) }
    end

    # "Set" means set to something. `payload_validators` defaults to `{}` and
    # `require_account` to `false`, and counting a default as a setting would
    # make every app look half-configured and every boot fail.
    def set?(value)
      return false if value.nil?
      return false if value.respond_to?(:empty?) && value.empty?

      true
    end

    # The names of the settings that are still unset, for the error message. A
    # message that says which three are missing is worth more than one that says
    # "invalid configuration", which is what a boot failure usually turns into.
    def missing_settings
      REQUIRED.reject { |name| set?(public_send(name)) }
    end

    # The keyword arguments for `TokenVerifier.new`, with `nil` for everything
    # the host did not set so the verifier's own defaults apply. Passing `nil`
    # rather than omitting a key is deliberate: a default belongs to the class
    # that documents it, not to a configuration object that a reader has to
    # cross-reference.
    def to_token_verifier_options
      {
        issuer: identity_issuer,
        audience: audience,
        jwks_url: jwks_url,
        jwks_cache_ttl: jwks_cache_ttl,
        jwks_timeout: jwks_timeout,
        unknown_kid_ttl: unknown_kid_ttl,
        min_refresh_interval: min_refresh_interval,
        leeway: leeway,
        account_claim: account_claim,
        scope_claims: scope_claims,
        require_account: require_account,
        clock: clock,
        logger: logger
      }.compact
    end

    # Copy whatever a host wrote into `config.cafaye` over the top of this.
    #
    # A `nil` in the host's options means "not set", not "set to nil", so
    # `config.cafaye.audience = nil` does not silently erase an audience an
    # initializer already set — and a host that uses both mechanisms gets the
    # union rather than one silently winning.
    # Fill in whatever this configuration does not already have, from a host's
    # `config.cafaye` block. See `merge_from` for why it fills gaps rather than
    # overwriting.
    def merge_from(options)
      return self if options.nil?

      options.each do |key, value|
        next unless set?(value)

        writer = "#{key}="
        # Gaps only. An initializer's `Cafaye.configure` runs after
        # `config/application.rb` and is the more specific of the two, so it wins;
        # `config.cafaye` supplies whatever the initializer left unset. A `nil` or
        # an empty value in the host's options means "not set" rather than "set to
        # nothing", so a host that uses both mechanisms gets the union rather than
        # one silently erasing the other.
        public_send(writer, value) if respond_to?(writer) && public_send(key).nil?
      end
      self
    end
  end
end
