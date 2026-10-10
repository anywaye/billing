# frozen_string_literal: true

require_relative "lib/cafaye/version"

Gem::Specification.new do |spec|
  spec.name = "cafaye"
  spec.version = Cafaye::VERSION
  spec.authors = [ "cafaye" ]
  spec.summary = "JWKS-backed token verification and a transactional outbox for cafaye services."
  spec.description = <<~TEXT.tr("\n", " ").strip
    The shared Ruby library every cafaye service depends on so that no service
    hand-rolls token verification or the outbox insert. Verifies RS256 bearer
    tokens against identity's published JWKS, and writes core's event envelope
    into a Postgres outbox inside the caller's own transaction.
  TEXT
  spec.homepage = "https://cafaye.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => "https://cafaye.com",
    "source_code_uri" => "https://github.com/cafaye/cafaye-rb",
    "changelog_uri" => "https://github.com/cafaye/cafaye-rb/blob/master/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "db/**/*.sql",
    "LICENSE.txt",
    "README.md",
    "CHANGELOG.md"
  ]
  spec.require_paths = [ "lib" ]

  # The two contracts this gem exists to own. See the Gemfile for the full
  # reasoning; the short form is that both are crypto/transaction paths where a
  # hand-rolled version is an incident.
  spec.add_dependency "jwt", "~> 3.1"
  spec.add_dependency "pg", "~> 1.5"

  # Optional, and only needed by the Rails half. Declared here rather than in the
  # Gemfile so `gem "cafaye"` in a non-Rails service does not drag in an ORM.
  spec.add_development_dependency "activerecord", "~> 8.1"
  spec.add_development_dependency "railties", "~> 8.1"
end
