# frozen_string_literal: true

require "digest"
require "pathname"
require "test_helper"

class VendoredGemTest < ActiveSupport::TestCase
  VENDOR = Pathname.new(File.expand_path("../../vendor/anywaye", __dir__))

  test "every vendored file is the file the manifest pinned" do
    drifted = DIGESTS.reject do |relative, digest|
      file = VENDOR.join(relative)
      file.exist? && Digest::SHA256.hexdigest(file.binread) == digest
    end

    assert_empty drifted.keys,
      "vendor/anywaye no longer matches its DIGESTS manifest. Either an edit crept " \
      "into the copy — revert it — or the pin was deliberately refreshed: re-copy " \
      "the gem's shipped files, rewrite DIGESTS and VENDORED.md's commit in the " \
      "same commit, and say why."
  end

  test "the manifest covers exactly the files the vendored copy carries" do
    on_disk = Dir.glob("**/*", base: VENDOR).select { |path| File.file?(VENDOR.join(path)) }

    assert_empty DIGESTS.keys - on_disk, "the manifest names a file that is no longer vendored"
    assert_empty on_disk - DIGESTS.keys - [ "DIGESTS", "VENDORED.md" ],
      "the vendored copy carries a file the manifest does not pin; a copy with extras " \
      "is a fork wearing a pin"
  end

  test "the pinned commit is recorded" do
    note = VENDOR.join("VENDORED.md").read
    assert_match(/\b[0-9a-f]{40}\b/, note, "VENDORED.md does not name the upstream commit it pins")
  end

  test "billing publishes with the shared gem's claim, not a second mechanism" do
    assert_includes Anywaye::Outbox::PgConnection::CLAIM_SQL, "for update skip locked"
    assert_includes Anywaye::Outbox::PgConnection::CLAIM_SQL, "published_at is null"
    assert_includes Anywaye::Outbox::PgConnection::CLAIM_SQL, "order by created_at, id"
    assert_kind_of Anywaye::Outbox::ActiveRecordConnection,
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

  DIGESTS = begin
    VENDOR.join("DIGESTS").read.lines.each_with_object({}) do |line, into|
      path, digest = line.strip.split(/\s+/, 2)
      into[path] = digest
    end
  end.freeze
end
