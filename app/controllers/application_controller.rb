class ApplicationController < ActionController::API
  include RequestTraceId
  include ProblemResponses
  include CursorPaging
  include IdempotentRequests
end
