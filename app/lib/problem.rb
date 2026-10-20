# The response body for every non-2xx this service sends.
#
# RFC 9457 `application/problem+json` with core's extensions, built in one place
# so that no controller can invent its own error shape. The parts that are not
# negotiable, from core's openapi-conventions.md:
#
# * `type` is a stable URI and `code` is its last segment, in snake_case. That
#   URI is the machine-readable contract; the `title` next to it is a summary a
#   client may reword.
# * `detail` is specific to this occurrence and is not parsed. It is also the
#   only free-text field, which is why INTERNAL_DETAIL is a constant: a failure
#   message never returns to an HTTP caller. The cause goes to the log, and
#   support starts from the trace id.
# * `errors[]` appears only on a 422, listing the per-field failures.
class Problem
  MEDIA_TYPE = "application/problem+json"
  TYPE_BASE = "https://docs.cafaye.com/errors"

  # core's envelope dialect, pinned on this service's own terms.
  SPEC_VERSION = "1.0"

  INTERNAL_DETAIL = "The request could not be completed. The cause is in the server log, keyed by this trace id."

  # The codes this service can answer with, and the status each one means.
  #
  # `bad_request`, `cursor_invalid` and `cursor_expired` are the three that core
  # does not name: its reserved list starts at 401, and it names
  # `cursor_expired` in the pagination section without listing it. They are
  # recorded as a decision for the manager in CHANGELOG.md rather than invented
  # quietly.
  #
  # **`unauthorized` (401) is core's own reserved code and is here for `/v1`'s
  # token check.** It is the *only* new status this service answers for
  # authentication, and the table still has **no 403** — deliberately, and the
  # property is asserted in `test/tenant/cross_account_web_test.rb`. A caller whose
  # token is good but who named another account's row gets the same 404 a caller
  # naming a row that does not exist gets, because a 403 would say "this exists,
  # you may not have it", which is an enumeration oracle. Absence, never refusal.
  CATALOG = {
    bad_request: { title: "Bad request", status: :bad_request },
    cursor_invalid: { title: "Invalid cursor", status: :bad_request },
    cursor_expired: { title: "Cursor expired", status: :bad_request },
    unauthorized: { title: "Unauthorized", status: :unauthorized },
    not_found: { title: "Not found", status: :not_found },
    conflict: { title: "Conflict", status: :conflict },
    idempotency_key_reused: { title: "Idempotency key reused", status: :conflict },
    validation_failed: { title: "Validation failed", status: :unprocessable_content },
    insufficient_tokens: { title: "Insufficient tokens", status: :payment_required },
    internal: { title: "Internal error", status: :internal_server_error },
    unavailable: { title: "Service unavailable", status: :service_unavailable }
  }.freeze

  attr_reader :code, :detail, :trace_id, :instance, :errors, :cause

  def initialize(code:, detail:, trace_id:, instance:, errors: nil, cause: nil)
    entry = CATALOG.fetch(code) { raise ArgumentError, "unknown problem code #{code.inspect}" }

    @code = code
    @title = entry.fetch(:title)
    @status = Rack::Utils.status_code(entry.fetch(:status))
    @detail = detail
    @trace_id = trace_id
    @instance = instance
    @errors = errors
    @cause = cause
  end

  attr_reader :title, :status

  def to_h
    body = {
      "type" => "#{TYPE_BASE}/#{code}",
      "title" => title,
      "status" => status,
      "detail" => detail,
      "instance" => instance,
      "code" => code.to_s,
      "trace_id" => trace_id
    }
    # core: `errors[]` appears only for 422.
    body["errors"] = errors if errors
    body
  end

  # The one place a cause is allowed to go. It carries the trace id the caller
  # was given, so an operator holding a response body can find the line.
  def log_cause
    Rails.logger.error("[#{trace_id}] #{instance}: #{cause.class}: #{cause.message}")
  end
end
