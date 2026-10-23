# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# `anywaye.yml`, against core's frozen manifest schema.
#
# `anywaye.yml` is the one place that declares this repository's identity, its core
# constraint and who owns it, and `core`'s schema is `additionalProperties:
# false` — so a field core does not define is a validation failure, not a
# comment. A manifest that drifts is a manifest `cafe new` and `pantry` read as
# fact and are wrong about.
#
# Core ships no JSON Schema validator and neither does this gem — a validator is a
# dependency that has to earn its place, and for five constraints it does not earn
# one. What is checked is each constraint core states, against core's own file
# where core is on disk, so the check cannot drift from the schema the way a
# hand-copied pattern can.
class ManifestTest < TestSupport::Test
  MANIFEST = File.expand_path("../../anywaye.yml", __dir__)

  def setup
    super
    @manifest = YAML.safe_load_file(MANIFEST, permitted_classes: [], aliases: false)
    @schema = read_schema
  end

  # --- the fields core requires --------------------------------------------

  def test_it_carries_every_field_core_requires_and_nothing_else
    # `additionalProperties: false`, so an undeclared field is a validation
    # failure rather than a comment. The manifest must be a superset of core's
    # `required` and a subset of core's `properties`; the fields in between are
    # the optional ones, and a library omitting `exposes` is one of them.
    allowed = @schema ? @schema.fetch("properties").keys : %w[name language core repository owner]
    required = @schema ? @schema.fetch("required") : allowed

    assert_empty @manifest.keys - allowed, "the manifest carries a field core's schema does not define"
    assert_empty required - @manifest.keys, "the manifest is missing a field core requires"
  end

  # --- the values core constrains ------------------------------------------

  def test_the_name_is_a_anywaye_namespace_name
    pattern = @schema ? @schema.dig("$defs", "serviceName", "pattern") : "^[a-z][a-z0-9]*(-[a-z0-9]+)*$"

    assert_match(/\A#{Regexp.new(pattern).source.delete_prefix("^").delete_suffix("$")}\z/, @manifest.fetch("name"))
  end

  def test_the_language_is_one_of_the_ones_core_accepts
    # `ruby`, for a gem. The alternative for a repository that ships no runtime
    # is `spec`, which is for specification-only repositories; this one has a
    # runtime and a `Gemfile`, so `ruby` is the honest answer.
    assert_includes %w[go ruby elixir python typescript rust spec], @manifest.fetch("language")
    assert_equal "ruby", @manifest.fetch("language")
  end

  def test_the_core_constraint_is_a_semver_range_core_accepts
    pattern = @schema ? @schema.dig("$defs", "semverRange", "pattern") : '^(\^|~|>=)?[0-9]+\.[0-9]+\.[0-9]+$'

    assert_match(/\A#{Regexp.new(pattern).source.delete_prefix("^").delete_suffix("$")}\z/, @manifest.fetch("core"))
  end

  def test_the_remote_is_ssh_and_never_https
    # core's schema rejects an HTTPS remote outright, because remotes for
    # anything anywaye owns are SSH and a bad habit should fail the suite rather
    # than be caught in review.
    assert_match(%r{\Agit@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?\z}, @manifest.dig("repository", "url"))
    refute_match(%r{https://}, @manifest.dig("repository", "url"))
  end

  def test_the_remote_is_the_one_the_manager_asked_for
    assert_equal "git@github.com:anywaye/anywaye-rb.git", @manifest.dig("repository", "url")
  end

  def test_the_default_branch_is_master
    assert_equal "master", @manifest.dig("repository", "defaultBranch")
  end

  def test_the_visibility_is_public
    assert_equal "public", @manifest.dig("repository", "visibility")
  end

  def test_the_owner_is_a_team_in_the_namespace
    assert_match(/\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/, @manifest.dig("owner", "team"))
    assert_equal "anywaye", @manifest.dig("owner", "team")
  end

  def test_the_description_is_one_sentence_and_fits
    assert_operator @manifest.fetch("description").length, :<=, 200
    assert_operator @manifest.fetch("description").length, :>, 20
  end

  # --- what a library declares, and does not -------------------------------

  def test_a_library_declares_no_contract_surface
    # core's schema says to omit `exposes` entirely for libraries, and gives it
    # `minProperties: 1`, so an empty `exposes` is a validation failure rather
    # than a way of saying "nothing yet". This repository is deployed nowhere,
    # serves no traffic and publishes no events.
    refute @manifest.key?("exposes"),
           "a library must omit exposes entirely; an empty one fails core's minProperties"
  end

  def test_it_consumes_no_events
    # A library is not a consumer. Naming event types it does not handle would
    # make every SDK generator emit a subscriber for a gem with no bus connection.
    assert_equal [], @manifest.fetch("consumes", [])
  end

  def test_its_only_service_dependency_is_identity
    # The dependency is real rather than a data reference: the token contract
    # this gem verifies is identity's — its issuer, its audience and its signing
    # keys are all identity's.
    assert_equal [ "identity" ], @manifest.fetch("dependencies").map { |d| d.fetch("name") }
    assert(@manifest.dig("dependencies", 0, "required"), "identity is not optional")
  end

  # --- the open decisions --------------------------------------------------

  def test_every_open_decision_is_in_the_manifest_and_not_only_in_a_commit
    # core's rule, and the one that matters most for this repository: "Undecided
    # and unreported is the only real failure." The claim-name conflict and the
    # shared-library contradiction are both in the file, by name, with the
    # alternatives and the cost of flipping.
    text = File.read(MANIFEST)

    assert_match(/DECISION NEEDED \(anywaye-rb-01\)/, text)
    assert_match(/event-outbox\.md/, text)
    assert_match(/ALGORITHMS|RS256/, text)
  end

  def test_the_numbered_decisions_are_referenced_consistently
    # "One number per decision, ever — a reused number is a broken
    # cross-reference, and a reference to a number that does not exist is worse
    # than no reference at all."
    #
    # Scanned from the commented `> ` marker, because a decision id is also *quoted* in
    # prose here — this manifest cites `DECISION NEEDED (guard, guard-02)` as the
    # other half of the claim-name conflict, and a decision header is not a
    # citation.
    #
    # The decisions live in YAML *comments*, which is the house convention and
    # also what keeps them clear of `additionalProperties: false`: a decision is
    # prose for a manager, not a field the schema defines. Both of this
    # repository's own decisions carry the packet's id rather than a number, so
    # the check is that neither has drifted into a bare number that would collide
    # with a future one.
    headers = File.read(MANIFEST).scan(/^#\s*>\s*DECISION NEEDED \(([^)]+)\)/).flatten

    assert_equal 2, headers.size, "expected two decision headers in anywaye.yml, found #{headers.size}"
    headers.each { |id| assert_match(/anywaye-rb-01/, id) }
  end

  private

  def schema_path
    File.expand_path("../../../core/schemas/anywaye.manifest.schema.json", __dir__)
  end

  def read_schema
    @read_schema = begin
      JSON.parse(File.read(schema_path))
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
  end
end
