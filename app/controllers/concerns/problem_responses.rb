# Every non-2xx answer this service gives, in the one shape core's
# openapi-conventions.md defines.
#
# The mapping from an Active Record error to core's `errors[].code` is a table
# rather than a `case` scattered over controllers, so a new validation does not
# quietly become an `invalid` that means nothing. The `detail` sentence is
# built from the same table, which keeps the human text and the machine code
# from drifting apart.
module ProblemResponses
  extend ActiveSupport::Concern

  Failure = Data.define(:field, :code, :message) do
    # core's `errors[]` entry: a field and a code, and nothing else.
    def as_error
      { "field" => field, "code" => code }
    end
  end

  CODES = {
    blank: "blank",
    taken: "taken",
    inclusion: "not_included",
    invalid_format: "invalid_format",
    format: "invalid_format",
    too_long: "too_long",
    too_short: "too_short",
    not_a_number: "invalid_format",
    not_an_integer: "invalid_format",
    greater_than_or_equal_to: "out_of_range",
    greater_than: "out_of_range",
    less_than: "out_of_range",
    less_than_or_equal_to: "out_of_range"
  }.freeze

  MESSAGES = {
    blank: "is required",
    taken: "is already in use",
    inclusion: "is not one of the allowed values",
    format: "is not in the expected format",
    too_long: "is too long",
    too_short: "is too short",
    not_a_number: "must be a number",
    not_an_integer: "must be a whole number",
    greater_than_or_equal_to: "must be greater than or equal to",
    greater_than: "must be greater than",
    less_than: "must be less than",
    less_than_or_equal_to: "must be less than or equal to"
  }.freeze

  MODEL_AUTHORED_TYPES = %i[invalid_format].freeze

  DEFAULT_CODE = "invalid"
  DEFAULT_MESSAGE = "is not valid"

  included do
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_bad_request
    rescue_from ActionController::ParameterMissing, with: :render_bad_request
    rescue_from ParameterError, with: :render_parameter_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
  end

  private
    def render_problem(code, detail:, errors: nil, cause: nil)
      problem = Problem.new(
        code: code,
        detail: detail,
        trace_id: trace_id,
        instance: request.path,
        errors: errors,
        cause: cause
      )
      problem.log_cause if cause
      set_trace_id_header

      render json: problem.to_h, content_type: Problem::MEDIA_TYPE, status: problem.status
    end

    # A model's failures, plus anything the request parsing refused before the
    # model saw it, as one 422.
    #
    # A `:taken` failure is a 409 rather than a 422 and carries no `errors[]`:
    # the request was well-formed, it just collides. That is the line between
    # "you sent something wrong" and "that already exists", and core's reserved
    # codes put them on different sides of it.
    #
    # `except` drops the model's own complaints about columns that a request-level
    # failure has already accounted for; `rename` reports a model's complaint
    # against the field the client actually sent, when the model only knows the
    # columns that field is stored in. Both exist so that one problem is reported
    # once, under the name the caller used.
    def render_validation_failure(record, extra_failures = [], except: [], rename: {})
      failures = record.errors.filter_map do |error|
        next if except.map(&:to_s).include?(error.attribute.to_s)

        field = rename.fetch(error.attribute.to_sym) { error.attribute.to_s }

        failure_for(field, error.type, error.message)
      end + extra_failures

      conflicts = failures.select { |failure| failure.code == "taken" }
      return render_problem(:conflict, detail: describe(conflicts)) if conflicts.any?

      render_problem(:validation_failed, detail: describe(failures), errors: failures.map(&:as_error))
    end

    def failure_for(field, type, message)
      Failure.new(
        field: field.to_s,
        code: CODES.fetch(type, DEFAULT_CODE),
        message: "#{field} #{humanize(type, message)}"
      )
    end

    # A model's own message where it chose the type, and this module's table
    # otherwise — so a 422's `detail` reads in one voice rather than mixing
    # "price must be an object with an integer amount_minor" with Rails' "can't
    # be blank".
    def humanize(type, message)
      return message if MODEL_AUTHORED_TYPES.include?(type)

      MESSAGES.fetch(type, DEFAULT_MESSAGE)
    end

    def describe(failures)
      failures.map(&:message).join("; ")
    end

    def render_bad_request(_exception)
      render_problem(:bad_request, detail: "The request body could not be read as JSON.")
    end

    def render_parameter_error(exception)
      errors = exception.field ? [ { "field" => exception.field, "code" => exception.field_code || DEFAULT_CODE } ] : nil

      render_problem(exception.code, detail: exception.message, errors: errors)
    end

    def render_not_found(_exception)
      render_problem(:not_found, detail: "No record matches that identifier.")
    end

    def render_conflict(exception)
      render_problem(:conflict, detail: "That record already exists.", cause: exception)
    end
end
