require "test_helper"

# The pinned copy of the fleet's shared gem, held to its upstream.
#
# `vendor/cafaye` exists because the gem is not on rubygems and github is not
# reachable from this environment — see `vendor/cafaye/VENDORED.md`. A pinned
# copy is honest only while it stays pinned, so these tests read the upstream
# checkout whenever it is on disk and compare byte for byte.
#
# The seam is `CAFAYE_RB_PATH` with the standard fleet layout as its default
# (`../..` from this worktree is `moon/`, and the shared gem lives at
# `cafaye/cafaye-rb` beside it). When the upstream is absent the drift test
# skips with that sentence printed — the same seam, and the same limitation,
# `test/contract/`'s core checks already carry: a developer with the fleet
# checked out beside them gets the guarantee, and CI cannot reach a private
# repository. The two tests that never skip are the ones about what the gem is
# *for*: the claim mechanism billing publishes with is the shared gem's, and
# the index it orders through exists in this repository's schema.
class VendoredGemTest < ActiveSupport::TestCase
  VENDOR = Rails.root.join("vendor/cafaye").to_s
  UPSTREAM = (ENV["CAFAYE_RB_PATH"].presence || Rails.root.join("../../cafaye/cafaye-rb").expand_path).to_s

  # Every file the gem's own gemspec ships. The vendored copy carries exactly
  # these and `VENDORED.md`; a file that appears or disappears upstream changes
  # this list, and the drift test notices.
  SHIPPED_FILES = %w[
    cafaye.gemspec
    db/outbox_events.sql
    lib/cafaye.rb
    lib/cafaye/configuration.rb
    lib/cafaye/errors.rb
    lib/cafaye/generators/outbox_generator.rb
    lib/cafaye/generators/templates/create_outbox_events.rb
    lib/cafaye/jwks/cache.rb
    lib/cafaye/jwks/fetcher.rb
    lib/cafaye/jwks/key_set.rb
    lib/cafaye/jwks/transport.rb
    lib/cafaye/outbox.rb
    lib/cafaye/outbox/active_record_connection.rb
    lib/cafaye/outbox/envelope.rb
    lib/cafaye/outbox/pg_connection.rb
    lib/cafaye/outbox/publisher.rb
    lib/cafaye/outbox/writer.rb
    lib/cafaye/principal.rb
    lib/cafaye/railtie.rb
    lib/cafaye/token.rb
    lib/cafaye/token_verifier.rb
    lib/cafaye/version.rb
    LICENSE.txt
    README.md
    CHANGELOG.md
  ].freeze

  test "the vendored copy is byte-identical to the upstream checkout" do
    skip("cafaye-rb is not on disk at #{UPSTREAM}; set CAFAYE_RB_PATH to the checkout") unless Dir.exist?(UPSTREAM)

    drifted = SHIPPED_FILES.reject do |relative|
      vendored = File.join(VENDOR, relative)
      upstream = File.join(UPSTREAM, relative)
      File.exist?(vendored) && File.exist?(upstream) && File.read(vendored) == File.read(upstream)
    end

    assert_empty drifted,
      "vendor/cafaye has drifted from #{UPSTREAM}. Re-copy the gem's shipped files, " \
      "and update VENDORED.md's pinned commit with the reason in the same commit."
  end

  test "the vendored copy ships nothing the gem does not" do
    vendored = Dir.glob("**/*", base: VENDOR).select { |path| File.file?(File.join(VENDOR, path)) }

    extras = vendored - SHIPPED_FILES - [ "VENDORED.md" ]
    assert_empty extras,
      "the vendored copy carries files the gemspec does not ship; a copy with extras " \
      "is a fork wearing a pin"
  end

  test "the pinned commit is recorded" do
    note = Rails.root.join("vendor/cafaye/VENDORED.md").read
    assert_match(/\b[0-9a-f]{40}\b/, note, "VENDORED.md does not name the upstream commit it pins")
  end

  test "billing publishes with the shared gem's claim, not a second mechanism" do
    # The claim is the second thing this gem exists to own, and the publisher
    # the relay builds is the gem's publisher over the gem's connection
    # adapter. This is the assertion that stops a second `for update skip
    # locked` being written in this repository: the SQL billing drains with is
    # the vendored gem's constant.
    assert_includes Cafaye::Outbox::PgConnection::CLAIM_SQL, "for update skip locked"
    assert_includes Cafaye::Outbox::PgConnection::CLAIM_SQL, "published_at is null"
    assert_includes Cafaye::Outbox::PgConnection::CLAIM_SQL, "order by created_at, id"
    assert_kind_of Cafaye::Outbox::ActiveRecordConnection,
      Outbox::Relay.send(:build_publisher, Outbox::NatsPublisher.build("nats://127.0.0.1:1"),
        logger: nil).instance_variable_get(:@connection)
  end

  test "the outbox table has the partial index the claim orders through" do
    indexes = ActiveRecord::Base.connection.indexes("outbox_events")
    unpublished = indexes.find { |index| index.name == "outbox_events_unpublished_idx" }

    assert_not_nil unpublished,
      "the generator's outbox_events_unpublished_idx is missing from this schema; " \
      "the claim's order by created_at has nothing to walk"
    assert_equal "(published_at IS NULL)", unpublished.where
    assert_equal [ "created_at" ], unpublished.columns
  end
end
