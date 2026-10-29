source "https://rubygems.org"

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "pg", "~> 1.1"
gem "puma", ">= 5.0"


gem "tzinfo-data", platforms: %i[ windows jruby ]

gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

gem "kamal", require: false

gem "thruster", require: false

gem "image_processing", "~> 1.2"


gem "stripe", "~> 20.0"
gem "sentry-ruby", "~> 5.24"
gem "sentry-rails", "~> 5.24"


gem "anywaye", path: "vendor/anywaye"

gem "ask-tokens", "~> 0.3.0"
gem "ask-tokens-rails", "~> 0.5.3"

gem "nats-pure", "~> 2.7"

gem "jwt", "~> 3.3"

gem "opentelemetry-sdk", "~> 1.13"
gem "opentelemetry-exporter-otlp", "~> 0.37"

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  gem "bundler-audit", require: false

  gem "brakeman", require: false

  gem "rubocop-rails-omakase", require: false

  gem "vcr"
  gem "webmock"
end
