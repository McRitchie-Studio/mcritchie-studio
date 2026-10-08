module Api
  module V1
    class BaseController < ActionController::API
      include Api::Paginatable
      include Api::AgentSessionGate

      before_action :authenticate_api!

      # The actions of a controller a harness key may call: the doors that mint a
      # login. Every other action answers a harness key 403.
      class_attribute :harness_key_actions, default: [].freeze

      def self.accepts_harness_key(*actions)
        self.harness_key_actions = actions.map(&:to_s).freeze
      end

      # rescue_from matches handlers in REVERSE registration order (the
      # last-declared wins). So the broad StandardError catch-all MUST be declared
      # FIRST — otherwise it shadows the specific handlers below it and a plain
      # RecordNotFound renders a 500 instead of a 404 (it did: `bin/reviewer-select`
      # got a 500 for an unknown slug). Keep specific handlers AFTER the catch-all.
      rescue_from StandardError, with: :handle_unexpected_error
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      # A foreign key or unique-index refusal answers 422 with the reason.
      include ConstraintViolationResponses

      private

      # Two bearers are accepted:
      #
      # - An agent session's token (AgentSession#token): the row is read on every
      #   call, so a revoked or expired session, a studio session whose task left
      #   building and review, or a reviewer's session whose claim is not live,
      #   answers 401 with the reason. A client session answers 403 everywhere but
      #   the endpoints its runtime key names (AgentSession::CLIENT_ENDPOINTS: Turf
      #   Monster's athletes read and game recap post). The session then sets
      #   Current.agent_session, which names the actor and drives the tier gates
      #   (Api::AgentSessionGate). A harness key (tier harness) is the exception: it
      #   is a machine's credential, so it sets Current.harness_key and no session,
      #   and only the actions a controller names with accepts_harness_key take it.
      # - The shared secret's token (POST /api/v1/auth), kept for one release so Turf
      #   Monster's two endpoints and installed hooks keep working. It must verify
      #   AND carry an expiry: MessageVerifier enforces an expiry when one is
      #   present, but a token minted without `expires_in` verifies forever. Each use
      #   is logged as legacy and counted in the legacy-use census (LegacyAuthUse).
      def authenticate_api!
        token = request.headers["Authorization"]&.sub(/\ABearer\s+/, "")
        return render_error("Missing token", status: :unauthorized, error_code: "UNAUTHORIZED") unless token.present?
        return authenticate_legacy_token!(token) if message_verifier.verified(token, purpose: :api_auth)

        authenticate_agent_session!(token)
      end

      def authenticate_legacy_token!(token)
        unless self.class.token_expiry(token)
          return render_error("Token carries no expiry; mint a fresh one at POST /api/v1/auth",
                              status: :unauthorized, error_code: "UNAUTHORIZED")
        end

        Rails.logger.info("[agent-auth] legacy shared-secret token: #{request.request_method} #{request.path}" \
                          "#{dropped_session_note}")
        LegacyAuthUse.record!(endpoint: endpoint_signature, caller: LegacyAuthUse.caller_for(request))
      end

      # A desk whose agent session was dropped (or expired) falls back to the shared
      # token and names the dropped session's slug in this header (bin/lib/desk_session.rb),
      # so the legacy log line still points at the desk. Client-asserted and used for the
      # log only, so anything that is not a plain slug is ignored.
      DROPPED_SESSION_HEADER = "X-Agent-Session-Dropped"
      DROPPED_SESSION_SLUG = /\A[a-z0-9][a-z0-9-]{0,63}\z/

      def dropped_session_note
        slug = request.headers[DROPPED_SESSION_HEADER].to_s.strip
        slug.match?(DROPPED_SESSION_SLUG) ? " (dropped desk session #{slug})" : ""
      end

      def authenticate_agent_session!(token)
        session = AgentSession.from_token(token)
        unless session
          return render_error("Invalid or expired token", status: :unauthorized, error_code: "UNAUTHORIZED")
        end

        reason = session.refusal_reason
        return render_error(reason, status: :unauthorized, error_code: "SESSION_ENDED") if reason
        return authenticate_harness_key!(session) if session.harness?
        return render_client_refusal(session) if session.client? && !session.reaches_endpoint?(endpoint_signature)

        Current.agent_session = session
      end

      # This action as AgentSession::CLIENT_ENDPOINTS and the legacy census name it.
      def endpoint_signature
        "#{request.request_method} #{controller_path}##{action_name}"
      end

      def render_client_refusal(session)
        routes = session.client_routes
        reason = if routes.empty?
                   "a client session reaches no board endpoint"
                 else
                   "a client session reaches no board endpoint but its own: #{session.soul}'s runtime key reaches " \
                     "#{routes.to_sentence} and nothing else"
                 end
        render_error(reason, status: :forbidden, error_code: "SESSION_FORBIDDEN")
      end

      def authenticate_harness_key!(key)
        unless harness_key_actions.include?(action_name)
          return render_error("a harness key mints studio logins (POST /api/v1/agent_sessions, a review claim) and posts " \
                              "login requests; it reaches no other endpoint. Write a task with the login its claim minted",
                              status: :forbidden, error_code: "SESSION_FORBIDDEN")
        end

        Rails.logger.info("[agent-auth] harness key #{key.slug} (#{key.label}): #{request.request_method} #{request.path}")
        Current.harness_key = key
      end

      # The `exp` a verified api_auth token carries, or nil when it has none. Call
      # it only AFTER verify: it reads the envelope Rails signed
      # ({"_rails":{"data":…,"exp":…,"pur":…}}, base64 before the "--" digest)
      # and trusts it because the signature already did. Anything it cannot read
      # as that envelope (a Marshal payload, a malformed message) is nil, which
      # refuses: this fails closed.
      def self.token_expiry(token)
        encoded = token.to_s.split("--", 2).first.to_s
        envelope = JSON.parse(Base64.strict_decode64(encoded))
        exp = envelope.is_a?(Hash) ? envelope.dig("_rails", "exp") : nil
        exp.presence
      rescue ArgumentError, TypeError, JSON::ParserError
        nil
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
