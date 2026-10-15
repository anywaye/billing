source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
# gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

# Stripe, the payment processor. This build uses it for two things:
# `Stripe::Webhook.construct_event` (the signature verification for inbound
# webhooks) and the three requests `Processor::StripeClient` makes out. Both are
# the processor's contract: the signature scheme (HMAC-SHA256 over
# `<timestamp>.<body>` with a tolerance window) re-implemented by hand would be
# a hand-rolled crypto path in the one place a forged amount must never be
# believed, and the three requests are the only outbound surface this service
# has. Every `Stripe::` call in this repository is one of the three
# `StripeClient` methods or `construct_event` — a checkable claim about the code
# rather than a sentence in a README.
gem "stripe", "~> 19.6"

# There is no `pay` gem here any more, and the gap it left is deliberate.
#
# `pay` was the "several processors behind one interface" abstraction, and what
# this service used from it was one thing: `FakeProcessor`, a processor whose
# API was its own Active Record tables, which is what made a checkout path
# runnable with no network and no keys. Everything else it brought — six STI
# tables, `Pay::Charge`/`Pay::Subscription` rows this service would then have
# had to reconcile with its own, and a bigint owner-id default that silently
# collapsed every uuid onto one row — was cost.
#
# `Processor::FakeClient` replaces it: a plain Ruby object, one `subscribe`
# method, a process-local ledger for the specs, no migration. The production
# Stripe surface was never pay's — it is `Processor::StripeClient`, three
# methods — and a second processor arriving is a `Processor::PaddleClient`
# with the same shape, not a gem that owns its own schema. See
# `REPORT-billing-fake-client-01.md` for the exit.

# The transactional outbox substrate, from the fleet's shared gem `cafaye-rb`.
#
# This is the gem that owns the outbox claim (`select ... for update skip
# locked`), the envelope grammar and the publish pass — one mechanism for the
# whole fleet, so billing's publisher does not carry a second answer to "how is
# a batch claimed". A publisher in billing that bypassed it would be a second
# mechanism for one thing, which is the thing the gem exists to prevent.
#
# WHY A PATH GEM AT `vendor/cafaye` AND NOT A RELEASED OR GIT DEPENDENCY: the
# gem is not published to rubygems.org and github.com/cafaye/cafaye-rb is not
# reachable from this environment (both verified). Until the fleet publishes it
# — see the report, `cafaye-rb` at 5056500 is the pinned copy — this is the
# pinned source of the same bytes, not a fork: `VENDORED.md` records the commit
# and `test/contract/vendored_gem_test.rb` fails when the copy drifts from the
# upstream checkout whenever that checkout is on disk. The gem's own Railtie is
# inert unless a host configures it, so this dependency configures nothing.
gem "cafaye", path: "vendor/cafaye"

# The broker client. billing publishes its outbox onto the fleet's NATS bus, and
# this is the one gem that decision costs — the transport is the piece the
# shared gem deliberately does not own (its README: "It is not a bus client"),
# because it is the one decision that belongs to the service.
#
# JetStream, not core NATS: `published_at` is set from the broker's
# acknowledgement, and only JetStream's `publish` blocks until the broker acks.
# A core-NATS publish returns when the bytes are on the wire, so marking on its
# return would mark rows published the broker never stored — an event announced
# and lost, which is the failure the outbox exists to prevent. See
# `Outbox::NatsPublisher`.
#
# `nats-pure`, not `nats`: the `nats` gem on rubygems is the 2018
# EventMachine client with no JetStream and a C extension of its own. The
# maintained pure-Ruby client is published under this name.
gem "nats-pure", "~> 2.7"

# Identity's access tokens. billing is the first service in the fleet to verify
# them, and it verifies them with this gem rather than by hand for the reason the
# stripe gem is above: RS256 signature checking is the one place a forged amount
# must never be believed, and a hand-rolled verifier is exactly the thing that
# gets `alg: none` and HS256-with-the-public-key wrong.
#
# The claim this service makes is narrower than "we read a token": it is that
# `/v1` is **locked** unless a deployment configures an issuer and an audience,
# and that an unconfigured or unreachable identity is a refusal rather than an
# open door. See `Identity::TokenVerifier` and `RequirePrincipal`.
gem "jwt", "~> 3.3"

# OpenTelemetry. The trace SDK and the OTLP exporter, and the reason each is named
# here is in app/lib/kit/telemetry.rb: without them billing cannot emit a span at
# all, and the collector kit ships with the stack has nothing to redact.
#
# In EVERY group, including test: `BILLING_OTEL_ENDPOINT` is ON BY DEFAULT (core
# D16), so a developer running `bin/rails server` exports into the collector that
# ships with the stack, and a deployer gets traces without assembling them.
# Gating the exporter to production would make the default a no-op everywhere it
# is actually used, which is backwards — and it would make the redaction tests in
# this repository assert nothing, because a suite with no exporter exports nothing.
#
# Deliberately NOT added, each with a reason rather than a preference:
#
#   * opentelemetry-instrumentation-rails / -rack. `use_all!` records
#     `http.target`, `url.full`, `url.query` and request headers as its own span
#     attributes. Those are exactly the values a redacting collector strips, and
#     depending on the engine to strip them would make billing's boundary ONE
#     control where this repository insists on TWO. Hence a hand-rolled Rack
#     middleware in app/middleware/, which records only what
#     `Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES` permits.
#   * opentelemetry-exporter-otlp-metrics. Metrics come from kit's collector's
#     `spanmetrics` connector, which derives them from spans AFTER redaction — so
#     a derived metric can never carry a dimension the allowlist stripped, and
#     there is no second definition of the same series anywhere in the fleet.
#   * opentelemetry-instrumentation-logger / opentelemetry-logs. Logs are the
#     container's stdout: compose's `logging:` driver ships them to the
#     collector's `syslog/crash` receiver, which makes a panic a log record with a
#     `service.name` on it and adds no per-language dependency to this repository.
gem "opentelemetry-sdk", "~> 1.13"
gem "opentelemetry-exporter-otlp", "~> 0.37"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end
