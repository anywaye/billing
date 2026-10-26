class MetricsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    registry = Prometheus::Client.registry
    render plain: Prometheus::Client::Formats::Text.marshal(registry), content_type: "text/plain; version=0.0.4; charset=utf-8"
  end
end
