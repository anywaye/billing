require "vcr"

VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock

  config.filter_sensitive_data("<STRIPE_API_KEY>") { ENV["STRIPE_API_KEY"] }
  config.filter_sensitive_data("<STRIPE_SECRET_KEY>") { ENV["STRIPE_SECRET_KEY"] }
  config.filter_sensitive_data("<STRIPE_WEBHOOK_SECRET>") { ENV["STRIPE_WEBHOOK_SECRET"] }

  config.allow_http_connections_when_no_cassette = false

  config.default_cassette_options = {
    record: :once,
    match_requests_on: [ :method, :uri, :body ]
  }
end
