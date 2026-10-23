# frozen_string_literal: true

require_relative "test_helper"

# The gate's own subject, asserted like everything else.
#
# It is here because a version constant is the one thing in this repository that
# nothing else in the suite would notice if it went missing, and `anywaye.gemspec`
# `require_relative`s this file — so a broken version constant fails the gem
# build, not a test that runs after it.
class VersionTest < TestSupport::Test
  def test_the_version_is_a_three_segment_number
    assert_match(/\A\d+\.\d+\.\d+\z/, Anywaye::VERSION)
  end

  def test_the_gemspec_reads_the_same_version
    spec = Gem::Specification.load(File.expand_path("../anywaye.gemspec", __dir__))

    assert_equal(Anywaye::VERSION, spec.version.to_s)
  end

  def test_the_gemspec_depends_on_the_two_runtime_gems
    spec = Gem::Specification.load(File.expand_path("../anywaye.gemspec", __dir__))

    assert_equal(%w[jwt pg], spec.runtime_dependencies.map(&:name).sort)
  end
end
