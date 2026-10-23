# frozen_string_literal: true

require_relative "test_helper"
require "rubygems"

# What actually ships.
#
# A gem that works from a checkout and does not work from `gem install` is a gem
# whose first real user is a service that cannot run it, and the failure is a
# `LoadError` in a publisher loop. The checks here are the packaging ones: the
# file list, the runtime dependencies, and the DDL file the outbox reads at
# runtime.
class PackagingTest < TestSupport::Test
  GEMSPEC_PATH = File.expand_path("../anywaye.gemspec", __dir__)
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_the_ships_files_list_includes_everything_the_gem_needs_at_runtime
    names = spec.files

    # The DDL is read at runtime by `Anywaye::Outbox.ddl`, and the generator's
    # template is read by `rails generate anywaye:outbox`. A `files` list that
    # missed either would produce a gem that installs and then cannot create its
    # own table.
    assert_includes names, "db/outbox_events.sql"
    assert_includes names, "lib/anywaye/generators/templates/create_outbox_events.rb"
    assert_includes names, "lib/anywaye.rb"
    assert_includes names, "README.md"
  end

  def test_every_shipped_ruby_file_exists
    spec.files.grep(/\.rb\z/).each do |name|
      assert_path_exists File.join(REPO_ROOT, name)
    end
  end

  def test_no_library_file_is_left_out_of_the_ships_list
    # The inverse check, which is the one that catches a file added under `lib/`
    # and forgotten here. A library file that is not in `files` is a file that is
    # not in the gem.
    on_disk = Dir[File.join(REPO_ROOT, "lib", "**", "*.rb")].map { |path| Pathname.new(path).relative_path_from(Pathname.new(REPO_ROOT)).to_s }
    # The generator template is ERB, not Ruby, and is listed separately.
    on_disk -= [ "lib/anywaye/generators/templates/create_outbox_events.rb" ]

    assert_empty(on_disk - spec.files, "a lib/ file is not in the gemspec's files list")
  end

  def test_the_runtime_dependencies_are_exactly_the_two_with_a_reason
    # `test/version_test.rb` asserts the names; this asserts the constraints,
    # which is where a dependency silently opens a major upgrade. They are
    # pessimistic on the minor as well as the major, so a new minor of `jwt` — a
    # JOSE library, where a minor can change what a verification accepts — is a
    # decision rather than an accident.
    assert_equal [ [ "jwt", "~> 3.1" ], [ "pg", "~> 1.5" ] ],
                 spec.runtime_dependencies.map { |d| [ d.name, d.requirement.to_s ] }.sort
  end

  def test_activerecord_and_railties_are_development_only
    # A service that does not use Rails must not install an ORM. They are in the
    # gemspec as development dependencies for exactly that reason, and this is the
    # assertion that keeps them there.
    development = spec.development_dependencies.map(&:name).sort

    assert_includes development, "activerecord"
    assert_includes development, "railties"
    assert_empty(spec.runtime_dependencies.map(&:name) & %w[activerecord railties rails])
  end

  def test_the_ddl_the_library_reads_is_the_file_a_service_is_told_to_copy
    assert_path_exists Anywaye::Outbox::DDL_PATH
    assert_equal File.join(REPO_ROOT, "db", "outbox_events.sql"), Anywaye::Outbox::DDL_PATH
  end

  def test_the_gem_can_be_required_from_outside_the_checkout
    # `$LOAD_PATH` has this repository's `lib` on it for the suite, which would
    # hide a file that is not in `files`. This resolves the library's own require
    # list against the shipped list instead.
    required = File.read(File.join(REPO_ROOT, "lib", "anywaye.rb")).scan(/^require "(anywaye[^"]*)"/).flatten
    shipped = spec.files.grep(%r{\Alib/})

    assert_operator required.size, :>, 8
    required.each do |feature|
      assert_includes shipped, "lib/#{feature}.rb", "#{feature} is required but not shipped"
    end
  end

  def test_the_rails_halves_are_optional_at_load_time
    # `lib/anywaye.rb` requires the railtie only when Rails is already there, so a
    # plain script can `require "anywaye"` without an ORM in the process. This is
    # asserted on the source rather than in a subprocess, because a subprocess per
    # Ruby version per CI matrix entry is a lot of machinery for one line.
    source = File.read(File.join(REPO_ROOT, "lib", "anywaye.rb"))

    assert_match(/require "anywaye\/railtie" if defined\?\(::Rails::Railtie\)/, source)
    assert_match(/require "anywaye\/outbox\/active_record_connection"/, File.read(File.join(REPO_ROOT, "lib", "anywaye", "outbox.rb")))
  end

  private

  def spec
    @spec ||= Gem::Specification.load(GEMSPEC_PATH)
  end
end
