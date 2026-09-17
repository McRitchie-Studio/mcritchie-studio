module Api
  module V1
    class BaseController < ActionController::API
      include Api::Paginatable

      before_action :authenticate_api!

      # rescue_from matches handlers in REVERSE registration order (the
      # last-declared wins). So the broad StandardError catch-all MUST be declared
      # FIRST — otherwise it shadows the specific handlers below it and a plain
      # RecordNotFound renders a 500 instead of a 404 (it did: `bin/reviewer-select`
      # got a 500 for an unknown slug). Keep specific handlers AFTER the catch-all.
      rescue_from StandardError, with: :handle_unexpected_error
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
      rescue_from ActiveRecord::RecordNotFound, with: :not_found

      private

      def authenticate_api!
        token = request.headers["Authorization"]&.sub(/\ABearer\s+/, "")
        return render_error("Missing token", status: :unauthorized, error_code: "UNAUTHORIZED") unless token.present?
        message_verifier.verify(token, purpose: :api_auth)
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        render_error("Invalid or expired token", status: :unauthorized, error_code: "UNAUTHORIZED")
      end

      def message_verifier
        Rails.application.message_verifier("api_auth")
      end

      # Standardized JSON response helpers
      def render_data(data, status: :ok, meta: nil)
        body = { data: data }
        body[:meta] = meta if meta
        render json: body, status: status
      end

      def render_error(message, status: :unprocessable_entity, error_code: nil)
        body = { error: message }
        body[:error_code] = error_code if error_code
        render json: body, status: status
      end

      # Render a rescued exception. Prefer this over `render_error(e.message)` at
      # a bare `rescue StandardError` site: a raw message alone is what made the
      # 2026-09-17 archive failure opaque — the operator got
      #
      #   422: 2231911675 is out of range for ActiveModel::Type::Integer with limit 4 bytes
      #
      # with no table, no column, and no task. The message half is now fixed in
      # the model layer (IntegerColumnRange names the column); this adds the
      # machine-readable code so `bin/task` and the board can tell a column-width
      # overflow apart from an ordinary validation refusal without parsing prose.
      ERROR_CODES = {
        "IntegerColumnRange::OutOfRangeColumnError" => "VALUE_OUT_OF_RANGE",
        "ActiveModel::RangeError" => "VALUE_OUT_OF_RANGE",
        "ActiveRecord::RecordInvalid" => "RECORD_INVALID",
        "ActiveRecord::RecordNotFound" => "NOT_FOUND"
      }.freeze

      def render_exception(exception, status: :unprocessable_entity)
        render_error(exception.message, status: status, error_code: error_code_for(exception))
      end

      def error_code_for(exception)
        ERROR_CODES[exception.class.name] ||
          ERROR_CODES.find { |name, _| exception.class.ancestors.any? { |a| a.name == name } }&.last
      end

      def not_found
        render_error("Not found", status: :not_found, error_code: "NOT_FOUND")
      end

      # Central error logging method — all API error logging flows through here.
      # Returns the ErrorLog record so callers can attach target/parent context.
      def create_error_log(exception)
        ErrorLog.capture!(exception)
      end

      def unprocessable(exception)
        create_error_log(exception)
        render_error(exception.message, status: :unprocessable_entity, error_code: "VALIDATION_FAILED")
      end

      # Layer 2: Opt-in per-action wrapper with target/parent context.
      # Sets @_error_logged flag so Layer 1 won’t double-log.
      def rescue_and_log(target: nil, parent: nil)
        yield
      rescue ActiveRecord::RecordNotFound => e
        raise e
      rescue StandardError => e
        error_log = create_error_log(e)
        # Guarded exactly as the engine's Studio::ErrorHandling#rescue_and_log
        # guards it. Unguarded, a slug-less target (a join row, a claim, an armed
        # action) raised NoMethodError from INSIDE the rescue — replacing the real
        # exception with a useless one and losing the ErrorLog that was the whole
        # point of the call.
        if target
          error_log.target = target
          error_log.target_name = target.slug if target.respond_to?(:slug)
        end
        if parent
          error_log.parent = parent
          error_log.parent_name = parent.slug if parent.respond_to?(:slug)
        end
        error_log.save!
        @_error_logged = true
        raise e
      end

      # Layer 1: Catch-all for unexpected errors — log + JSON 500.
      # Skips logging if rescue_and_log already captured it.
      def handle_unexpected_error(exception)
        create_error_log(exception) unless @_error_logged
        raise exception if Rails.env.development? || Rails.env.test?

        render_error("Internal server error", status: :internal_server_error, error_code: "INTERNAL_ERROR")
      end
    end
  end
end
