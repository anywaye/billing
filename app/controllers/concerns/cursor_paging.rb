# Cursor pagination, because core's openapi-conventions.md requires it on every
# collection and offset pagination cannot stay stable while rows are being
# inserted.
#
# A cursor is base64url of `{at, id}`: the last row of the page, by the same
# order the page was read in. The `id` is the tiebreaker, which is what makes
# the keyset total — two rows written in the same millisecond still have an
# order, and no row is repeated or skipped across a page boundary.
#
# It is base64url and nothing more. core calls a cursor opaque and says its
# encoding may change without notice, and a *signed* cursor would need a shared
# secret that this service does not have yet. Until it does, a crafted cursor
# can only ask for a different page of the same collection, and v0's endpoints
# are unauthenticated anyway (README). Signing it is a one-line change here when
# a secret exists, and the client is unaffected either way — that is the point
# of calling it opaque.
module CursorPaging
  extend ActiveSupport::Concern

  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100

  CURSOR_TTL = 24.hours

  Page = Data.define(:records, :next_cursor, :has_more)

  private
    def paginate(scope, order: :desc)
      limit = requested_limit
      direction = requested_order(fallback: order)

      scope = scope.order(created_at: direction, id: direction)
      scope = apply_cursor(scope, decode_cursor(params[:cursor]), direction) if params[:cursor].present?

      records = scope.limit(limit + 1).to_a
      has_more = records.size > limit
      records = records.first(limit)

      Page.new(records, has_more ? encode_cursor(records.last) : nil, has_more)
    end

    def render_page(page, serializer)
      render json: {
        data: page.records.map { |record| serializer.call(record) },
        page: { next_cursor: page.next_cursor, has_more: page.has_more }
      }
    end

    def requested_limit
      raw = params[:limit]
      return DEFAULT_LIMIT if raw.blank?

      limit = Integer(raw.to_s, 10, exception: false)
      if limit.nil? || limit < 1
        raise ParameterError.new(
          :validation_failed,
          "limit must be a whole number of rows",
          field: "limit",
          field_code: "invalid_format"
        )
      end

      [ limit, MAX_LIMIT ].min
    end

    def requested_order(fallback:)
      case params[:order].presence || fallback
      when :asc, "asc" then :asc
      when :desc, "desc" then :desc
      else
        raise ParameterError.new(
          :validation_failed,
          "order must be asc or desc",
          field: "order",
          field_code: "invalid_format"
        )
      end
    end

    def encode_cursor(record)
      payload = { "at" => record.created_at.utc.iso8601(6), "id" => record.id }

      Base64.urlsafe_encode64(payload.to_json, padding: false)
    end

    def decode_cursor(cursor)
      payload = JSON.parse(Base64.urlsafe_decode64(cursor.to_s))

      unless payload.is_a?(Hash) && payload["at"].is_a?(String) && payload["id"].is_a?(String)
        raise unreadable_cursor
      end

      issued_at = Time.iso8601(payload["at"])
      raise expired_cursor if issued_at < CURSOR_TTL.ago

      { at: issued_at, id: payload["id"] }
    rescue ArgumentError, JSON::ParserError
      raise unreadable_cursor
    end

    # Row comparison, so the two columns are compared as a pair and the `id`
    # tiebreaker only applies to rows whose timestamp is equal. `<` for
    # descending, `>` for ascending — the same order the page was read in.
    def apply_cursor(scope, cursor, direction)
      comparison = direction == :desc ? "<" : ">"

      scope.where("(created_at, id) #{comparison} (:at, :id)", at: cursor[:at], id: cursor[:id])
    end

    def unreadable_cursor
      ParameterError.new(:cursor_invalid, "cursor could not be read; it is opaque and may have changed")
    end

    def expired_cursor
      ParameterError.new(:cursor_expired, "cursor is older than #{CURSOR_TTL.inspect} and can no longer be used")
    end
end
