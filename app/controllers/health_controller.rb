# Liveness and readiness endpoints for orchestrators, load balancers and uptime
# monitors.
#
#   GET /healthz -> liveness. Answers as long as the process is serving requests.
#                  It touches no dependency on purpose: a liveness check that
#                  fails when the database is slow causes a restart storm.
#   GET /readyz  -> readiness. Verifies the one dependency this service cannot
#                  serve traffic without (PostgreSQL) and answers 503 when it
#                  is unavailable, so the load balancer stops sending requests.
class HealthController < ApplicationController
  # Liveness probe. No dependency checks.
  def show
    render json: { status: "ok" }
  end

  # Readiness probe. 503 + JSON body when a dependency check fails.
  def ready
    if database_available?
      render json: { status: "ok", checks: { database: "ok" } }
    else
      render json: { status: "error", checks: { database: "error" } }, status: :service_unavailable
    end
  end

  private
    def database_available?
      ActiveRecord::Base.lease_connection.exec_query("SELECT 1")
      true
    rescue ActiveRecord::ActiveRecordError, PG::Error => e
      Rails.logger.warn("readiness check failed: #{e.class}: #{e.message}")
      false
    end
end
