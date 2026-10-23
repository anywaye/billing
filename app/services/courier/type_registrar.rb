# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Courier
  # Registers billing's notification types in courier, so billing owns the
  # copy and templates of its own mail (receipt, payment_failed) and courier
  # stays a generic delivery engine.
  #
  # Run via `bin/rails courier:register_types`. Idempotent: an existing type
  # is updated (PATCH) rather than duplicated.
  class TypeRegistrar
    TYPES = [
      {
        "type" => "receipt",
        "kind" => "transactional",
        "required" => %w[email amount_display],
        "subject" => "We received your Anywaye payment",
        "html_template" => <<~EEX,
          <p><%= @greeting %></p>
          <p>We received your payment of <strong><%= @amount_display %></strong> for your Anywaye subscription. Thank you.</p>
          <%= if @invoice_id do %>
          <p>Keep this for your records. Your invoice is <strong><%= @invoice_id %></strong>.</p>
          <% end %>
          <p>You can see the receipt and manage your subscription at any time from your account.</p>
        EEX
        "text_template" => <<~EEX
          <%= @greeting %>

          We received your payment of <%= @amount_display %> for your Anywaye subscription. Thank you.
          <%= if @invoice_id do %>
          Keep this for your records. Your invoice is <%= @invoice_id %>.
          <% end %>
          You can see the receipt and manage your subscription at any time from your account.
        EEX
      },
      {
        "type" => "payment_failed",
        "kind" => "transactional",
        "required" => %w[email amount_display],
        "subject" => "Your Anywaye payment did not go through",
        "html_template" => <<~EEX,
          <p><%= @greeting %></p>
          <p>We could not process your payment of <strong><%= @amount_display %></strong> for your Anywaye subscription. Nothing was charged.</p>
          <%= if @invoice_id do %>
          <p>The attempt was for invoice <strong><%= @invoice_id %></strong>.</p>
          <% end %>
          <%= if @billing_url do %>
          <p>Please update your payment method here: <a href="<%= @billing_url %>"><%= @billing_url %></a></p>
          <% else %>
          <p>Please update your payment method from your account at any time.</p>
          <% end %>
          <p>You can manage your subscription at any time from your account.</p>
        EEX
        "text_template" => <<~EEX
          <%= @greeting %>

          We could not process your payment of <%= @amount_display %> for your Anywaye subscription. Nothing was charged.
          <%= if @invoice_id do %>
          The attempt was for invoice <%= @invoice_id %>.
          <% end %>
          <%= if @billing_url do %>
          Please update your payment method here: <%= @billing_url %>
          <% else %>
          Please update your payment method from your account at any time.
          <% end %>
          You can manage your subscription at any time from your account.
        EEX
      }
    ].freeze

    def self.register_all!
      url = ENV.fetch("COURIER_URL")
      token = ENV.fetch("COURIER_API_TOKEN")

      TYPES.each do |type_def|
        register_one!(url, token, type_def)
      end
    end

    def self.register_one!(url, token, type_def)
      type = type_def.fetch("type")
      uri = URI("#{url}/v1/notification_types/#{type}")

      # Try update first; if 404, create.
      req = Net::HTTP::Patch.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(type_def)

      response = http(uri).request(req)

      if response.code == "404"
        create_uri = URI("#{url}/v1/notification_types")
        create_req = Net::HTTP::Post.new(create_uri)
        create_req["Authorization"] = "Bearer #{token}"
        create_req["Content-Type"] = "application/json"
        create_req.body = JSON.generate(type_def)
        response = http(create_uri).request(create_req)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "courier register #{type}: #{response.code} #{response.body}"
      end

      Rails.logger.info("courier: registered notification type #{type}")
    end

    def self.http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http
    end
  end
end
