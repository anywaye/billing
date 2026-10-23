# The `X-Trace-Id` that core's conventions require on every response: the
# caller's id when they send one, a fresh uuid when they do not.
#
# It is not the same thing as `ActionDispatch::RequestId`, which reads
# `X-Request-Id`. anywaye's header is `X-Trace-Id`, so it is read and written
# here rather than borrowed — and it is written in an `after_action` so it is
# on the 200s too, not only on the failures.
module RequestTraceId
  extend ActiveSupport::Concern

  HEADER = "X-Trace-Id"

  included do
    before_action :assign_trace_id
    after_action :echo_trace_id
  end

  # Available to controllers and to the problem body.
  def trace_id
    @trace_id
  end

  # Writes the header. Called from the `after_action`, and again from the error
  # renderer: `rescue_from` runs *outside* the `process_action` callback chain,
  # so by the time a handler renders, the `after_action` has already run against
  # a response that was never committed. Without this second call every rescued
  # response — which is every 404, 409 and 422 — would ship without the id that
  # support starts from.
  def set_trace_id_header
    response.headers[HEADER] = trace_id
  end

  private
    def assign_trace_id
      @trace_id = request.headers[HEADER].presence || SecureRandom.uuid
    end

    def echo_trace_id
      set_trace_id_header
    end
end
