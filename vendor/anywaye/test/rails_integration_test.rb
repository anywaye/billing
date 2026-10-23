# frozen_string_literal: true

require_relative "test_helper"
require "rails"
require "active_record/railtie"
# `anywaye` was required by the test helper before Rails existed, so the railtie
# was not loaded — which is exactly the condition the `defined?(Rails::Railtie)`
# guard in `lib/anywaye.rb` exists for. A real app requires `rails/all` before
# Bundler.require, so it gets the railtie automatically; a test that requires the
# library first has to ask for it.
require "anywaye/railtie"

# The Railtie: what a host app gets by adding a gem and a config block.
#
# The rule it is built to is in the packet and in `guard`'s AGENTS.md: **it must
# be inert until configured.** An unconfigured app that raises at boot is a worse
# failure than an unconfigured app that does nothing, because the second one is
# visible in a log line and the first one takes the whole process down for a
# service that has not asked for anything yet.
class RailtieTest < TestSupport::Test
  def setup
    super
    Anywaye.reset!
    # A Rails app always has a database connection by the time an initializer
    # runs, and the outbox writer needs one it can enlist in. Established here so
    # the railtie is exercised the way a host app would exercise it.
    TestSupport::Database.reset_schema!
    ActiveRecord::Base.establish_connection(TestSupport::Database.url)
  end

  def teardown
    super
    ActiveRecord::Base.connection_handler.clear_all_connections!
    Anywaye.reset!
  end

  # --- inert until configured ----------------------------------------------

  def test_requiring_the_gem_configures_nothing
    # The weakest and most important assertion in the file. `require "anywaye"`
    # opens no connection, installs no middleware, reads no environment variable,
    # and leaves a configuration with nothing in it.
    refute_predicate Anywaye, :configured?
    assert_nil Anywaye.config.service_name
    assert_nil Anywaye.config.audience
  end

  def test_using_the_outbox_before_configuring_says_so_plainly
    # Inert means it does nothing *on its own*. A caller that reaches for the
    # writer before configuring has a programming error, and the message has to
    # name the thing that is missing rather than the regex that rejected it.
    error = assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye.outbox }

    assert_match(/Anywaye\.configure/, error.message)
  end

  def test_the_rail_tie_runs_and_does_nothing_when_nothing_is_configured
    # `install!` is what the Railtie calls from an initializer. Called with an
    # empty configuration it must be a no-op: no raise, no connection, no
    # verifier built.
    refute Anywaye::Railtie.install!(Anywaye.config)

    assert_empty logged_output
  end

  def test_an_app_with_the_gem_on_its_gemfile_and_no_config_block_still_boots
    # What that means in practice, asserted rather than asserted-about: the
    # railtie class is registered, and the configuration namespace a host writes
    # into exists and is empty.
    assert_operator Anywaye::Railtie, :<, Rails::Railtie
    assert_kind_of ActiveSupport::OrderedOptions, railtie_config
    assert_nil railtie_config.service_name
  end

  def test_a_service_name_on_its_own_is_refused_and_says_what_is_missing
    # A half-configured app is the dangerous middle: it has an opinion about
    # itself and no ability to verify a token. Failing at boot with the two
    # missing names is worth more than booting and refusing every request later,
    # and worth more than a verifier built from half the settings.
    Anywaye.configure { |config| config.service_name = "billing" }

    error = assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye::Railtie.install!(Anywaye.config) }

    assert_match(/identity_issuer/, error.message)
    assert_match(/audience/, error.message)
    refute_predicate Anywaye, :configured?
  end

  # --- a misconfiguration is a boot failure, not a 503 ---------------------

  def test_an_issuer_with_no_audience_fails_at_install_and_not_at_the_first_request
    # `guard`'s rule: "a typo in an environment variable that only surfaces as a
    # 503 on every request is a typo nobody finds."
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.identity_issuer = "https://identity.anywaye.com"
    end

    assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye::Railtie.install!(Anywaye.config) }
  end

  def test_an_audience_with_no_issuer_fails_at_install
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.audience = "anywaye-services"
    end

    assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye::Railtie.install!(Anywaye.config) }
  end

  def test_a_service_name_that_is_not_a_service_name_fails_at_install
    Anywaye.configure do |config|
      config.service_name = "Billing Service"
      config.identity_issuer = "https://identity.anywaye.com"
      config.audience = "anywaye-services"
    end

    assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye::Railtie.install!(Anywaye.config) }
  end

  def test_a_plain_http_issuer_off_loopback_fails_at_install
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.identity_issuer = "http://identity.anywaye.com"
      config.audience = "anywaye-services"
    end

    assert_raises(Anywaye::Errors::ConfigurationError) { Anywaye::Railtie.install!(Anywaye.config) }
  end

  # --- a configured app gets both halves -----------------------------------

  def test_a_fully_configured_app_gets_a_verifier_and_an_outbox_writer
    configure!

    Anywaye::Railtie.install!(Anywaye.config)

    assert_kind_of Anywaye::TokenVerifier, Anywaye.token_verifier
    assert_kind_of Anywaye::Outbox::Writer, Anywaye.outbox
    assert_predicate Anywaye.config, :configured?
  end

  def test_the_verifier_is_built_once_per_process
    # Two verifiers would fetch the key set twice and could disagree about
    # whether a rotation has happened, which is the one thing a key cache exists
    # to prevent.
    configure!
    Anywaye::Railtie.install!(Anywaye.config)

    assert_same Anywaye.token_verifier, Anywaye.token_verifier
  end

  def test_the_outbox_writers_source_is_the_service_name
    configure!

    Anywaye::Railtie.install!(Anywaye.config)

    assert_equal "billing", Anywaye.outbox.service_name
  end

  def test_installing_twice_is_harmless
    # An initializer is not a once-only hook in every host app's setup, and a
    # railtie that raised on a second call would be a railtie nobody could
    # re-run in a console.
    configure!
    Anywaye::Railtie.install!(Anywaye.config)

    assert_silent { Anywaye::Railtie.install!(Anywaye.config) }
    assert_kind_of Anywaye::Outbox::Writer, Anywaye.outbox
  end

  def test_it_points_the_library_logger_at_the_rails_logger
    configure!
    host_logger = Logger.new(IO::NULL)
    Anywaye::Railtie.install!(Anywaye.config, logger: host_logger)

    assert_same host_logger, Anywaye.logger
  end

  def test_the_configuration_a_host_writes_is_the_configuration_used
    # `config.anywaye.audience = "another-service"` in an environment file and
    # `Anywaye.configure { |c| c.audience = ... }` in an initializer are the same
    # setting. The initializer runs later in the boot order and is the more
    # specific of the two, so it wins — and the environment file fills in the
    # gaps rather than overwriting. A host that uses both gets the union.
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.identity_issuer = "https://identity.anywaye.com"
      config.audience = "anywaye-services"
    end
    railtie_config.audience = "another-service"
    railtie_config.jwks_cache_ttl = 120

    Anywaye::Railtie.install!(Anywaye.config)

    assert_equal "anywaye-services", Anywaye.token_verifier.audience
    assert_equal 120, Anywaye.token_verifier.jwks_cache_ttl
    assert_equal "another-service", railtie_config.audience
  ensure
    railtie_config.delete(:audience)
    railtie_config.delete(:jwks_cache_ttl)
  end

  # --- the migration generator ---------------------------------------------

  def test_the_generator_writes_core_s_table_into_the_host_app
    # The outbox table belongs to the service, in the service's repository, in
    # the service's own migration — core's wording, and this is the mechanism.
    # The generator copies the reference DDL into a timestamped migration.
    body = generate_migration

    assert_match(/class CreateOutboxEvents < ActiveRecord::Migration/, body)
    assert_match(/create_table :outbox_events/, body)
    assert_match(/where: "published_at IS NULL"/, body)
    assert_match(/outbox_events_unpublished_idx/, body)
  end

  def test_the_generator_refuses_to_overwrite_an_existing_migration
    with_generator_destination do |destination|
      2.times { run_generator(destination) }

      assert_equal 1, Dir[File.join(destination, "db", "migrate", "*.rb")].size
    end
  end

  def test_the_generator_migration_keeps_every_check_constraint_from_the_reference_ddl
    body = generate_migration

    # Every CHECK constraint in the reference DDL has to survive the trip into
    # the host app, or a service that used the generator has a weaker table than
    # one that copied the file.
    names = Anywaye::Outbox.ddl.scan(/constraint (\w+)/).flatten

    refute_empty names
    names.each { |constraint| assert_includes body, constraint }
  end

  private

  # Thor writes its progress to stdout, which is noise in a test run. Captured,
  # and the capture is where a generator that printed a stack trace would land
  # rather than in the middle of the suite's output.
  def with_generator_destination
    destination = File.join(Dir.tmpdir, "anywaye-generator-#{Process.pid}-#{rand(1 << 32)}")
    FileUtils.mkdir_p(destination)
    yield destination
  ensure
    FileUtils.rm_rf(destination)
  end

  def run_generator(destination)
    original = $stdout
    $stdout = StringIO.new
    Anywaye::Generators::OutboxGenerator.start([], destination_root: destination, quiet: true)
    $stdout.string
  ensure
    $stdout = original
  end

  def generate_migration
    with_generator_destination do |destination|
      run_generator(destination)
      Dir[File.join(destination, "db", "migrate", "*.rb")].then { |files| File.read(files.first) }
    end
  end

  def configure!
    Anywaye.configure do |config|
      config.service_name = "billing"
      config.identity_issuer = "https://identity.anywaye.com"
      config.audience = "anywaye-services"
    end
  end

  # The namespace a host app writes into: `config.anywaye.audience = …`.
  def railtie_config
    Anywaye::Railtie.config.anywaye
  end
end
