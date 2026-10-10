# frozen_string_literal: true

require "digest"
require "pathname"
require "test_helper"

# The pinned copy of the fleet's shared gem, held to its pin.
#
# `vendor/cafaye` exists because the gem is not on rubygems and github is not
# reachable from this environment — see `vendor/cafaye/VENDORED.md`. A pinned
# copy is honest only while it stays pinned, and a pin nothing can check is a
# pin in name only, so `DIGESTS` records a sha256 for every file the gem's
# gemspec ships and this test re-reads them on every run. There is no skip in
# this file: a check that passes by not running is the thing the copy exists to
# prevent.
#
# What the manifest can and cannot say. It can say the copy is byte-stable —
# an edit to a vendored file, or a re-copy, changes a digest and fails here.
# It cannot say the upstream has not moved, because nothing in CI can reach
# the private repository. That half is a developer workflow, documented in
# VENDORED.md: with the fleet checked out beside this worktree, `diff -r` the
# two trees and re-copy deliberately, rewriting the manifest and the pinned
# commit in the same commit.
class VendoredGemTest < ActiveSupport::TestCase
  VENDOR = Pathname.new(File.expand_path("../../vendor/cafaye", __dir__))

  test "every vendored file is the file the manifest pinned" do
    drifted = DIGESTS.reject do |relative, digest|
      file = VENDOR.join(relative)
      file.exist? && Digest::SHA256.hexdigest(file.binread) == digest
    end

    assert_empty drifted.keys,
      "vendor/cafaye no longer matches its DIGESTS manifest. Either an edit crept " \
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

  # The manifest, read once. A recorded-debt table may never become the thing
  # being iterated: this file IS the iterated table, and every entry in it is
  # asserted against a file that exists.
  DIGESTS = begin
    VENDOR.join("DIGESTS").read.lines.each_with_object({}) do |line, into|
      path, digest = line.strip.split(/\s+/, 2)
      into[path] = digest
    end
  end.freeze
end
