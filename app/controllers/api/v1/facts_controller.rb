module Api
  module V1
    # Facts about a person, a company or an app (Fact).
    #
    #   GET  /api/v1/facts?subject_type=&subject_slug=[&history=1]  the subject's current facts
    #   POST /api/v1/facts                  { fact: { subject_type, subject_slug, key, value,
    #                                         sensitivity, source_kind, source_ref, source_note } }
    #   POST /api/v1/facts/:slug/supersede  { fact: { value, source_kind, source_ref, source_note } }
    #   POST /api/v1/facts/:slug/retire
    #
    # An agent session only: the shared token answers 401 and a client session 403.
    # A studio session reads and writes ordinary facts; admin reads and writes
    # both. An identity-class value answers 422 IDENTITY_REFUSED; the caller
    # stores a pointer (the key with no value and its source) instead.
    class FactsController < BaseController
      ENCRYPTION_ENV = %w[ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
                          ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT].freeze

      before_action :require_agent_session!
      before_action :require_encryption!
      before_action :set_fact, only: %i[supersede retire]

      def index
        type = params[:subject_type].to_s
        slug = params[:subject_slug].to_s
        if type.blank? || slug.blank?
          return render_error("subject_type and subject_slug are required", error_code: "SUBJECT_REQUIRED")
        end

        facts = Fact.for_subject(type, slug).readable_at(current_agent_session.tier)
        facts = facts.current unless ActiveModel::Type::Boolean.new.cast(params[:history])
        render_data(facts.includes(:recorded_by_session).newest_first.map { |fact| fact_json(fact) })
      end

      def create
        fact = Fact.new(fact_params(:subject_type, :subject_slug, :key, :sensitivity))
        return refuse_sensitive_write if fact.sensitive? && !current_agent_session.admin?
        return render_invalid(fact) unless fact.valid?

        rescue_and_log { fact.save! }
        render_data(fact_json(fact), status: :created)
      end

      def supersede
        attrs = fact_params(:sensitivity).to_h.symbolize_keys
        return refuse_sensitive_write if attrs[:sensitivity] == "sensitive" && !current_agent_session.admin?

        successor = rescue_and_log(target: @fact) { @fact.supersede!(**attrs) }
        render_data(fact_json(successor), status: :created)
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e.record)
      end

      def retire
        rescue_and_log(target: @fact) { @fact.retire! }
        render_data(fact_json(@fact))
      rescue ActiveRecord::RecordInvalid => e
        render_invalid(e.record)
      end

      private

      def require_agent_session!
        session = current_agent_session
        return render_session_refusal("a client session reads and writes no facts") if session&.client?
        return if session

        render_error("facts need an agent session; the shared token carries none",
                     status: :unauthorized, error_code: "SESSION_REQUIRED")
      end

      def require_encryption!
        return if Fact.encryption_ready?

        render_error("fact encryption is not configured on this app: set #{ENCRYPTION_ENV.join(", ")}",
                     status: :service_unavailable, error_code: "ENCRYPTION_NOT_CONFIGURED")
      end

      def set_fact
        @fact = Fact.find_by!(slug: params[:slug])
        refuse_sensitive_write if @fact.sensitive? && !current_agent_session.admin?
      end

      def refuse_sensitive_write
        render_session_refusal("a sensitive fact needs an admin session; " \
                               "#{current_agent_session.soul} holds a #{current_agent_session.tier} session")
      end

      # `fact` is required as the wrapper; a JSON body sent flat is wrapped by Rails.
      def fact_params(*extra)
        params.fetch(:fact, {}).permit(:value, :source_kind, :source_ref, :source_note, *extra)
              .merge(recorded_by_session_slug: current_agent_session.slug)
      end

      def render_invalid(record)
        message = record.errors.full_messages.to_sentence
        identity = message.include?("store a pointer to the original")
        render_error(message, error_code: identity ? "IDENTITY_REFUSED" : "VALIDATION_FAILED")
      end

      def fact_json(fact)
        {
          slug: fact.slug,
          subject_type: fact.subject_type,
          subject_slug: fact.subject_slug,
          key: fact.key,
          value: fact.value,
          pointer: fact.pointer?,
          sensitivity: fact.sensitivity,
          source: { kind: fact.source_kind, ref: fact.source_ref, note: fact.source_note },
          recorded_by_session_slug: fact.recorded_by_session_slug,
          recorded_by: fact.recorded_by_session&.soul,
          recorded_at: fact.recorded_at&.iso8601,
          superseded_by_slug: fact.superseded_by_slug,
          retired_at: fact.retired_at&.iso8601
        }
      end
    end
  end
end
