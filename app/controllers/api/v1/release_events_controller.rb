module Api
  module V1
    class ReleaseEventsController < BaseController
      STEP_ALIASES = {
        "testing" => "review_tests",
        "assembling" => "assemble_release",
        "qa_deploying" => "deploy_qa",
        "confirming" => "ship_gate",
        "production_deploying" => "deploy_prod"
      }.freeze

      before_action :set_release

      def start
        record("started")
      end

      def complete
        record("completed")
      end

      def fail
        record("failed")
      end

      private

      def set_release
        @release = Release.find_by(slug: params[:slug])
        return if @release

        render_error("release not found", status: :not_found, error_code: "NOT_FOUND")
      end

      def record(status)
        return unless validate_usage!(status)

        event = @release.record_event!(
          step: normalized_step,
          status: status,
          **event_attributes
        )
        render_data(event, status: :created)
      rescue StandardError => e
        render_error(e.message)
      end

      def normalized_step
        raw = params[:step].to_s.strip
        STEP_ALIASES.fetch(raw, raw)
      end

      def event_payload
        raw = params[:event]
        raw = params unless raw.is_a?(ActionController::Parameters)
        raw.permit(
          :source, :actor, :model, :tokens_in, :tokens_out, :cost,
          :repo, :app, :sha, :url, :command, :message, :idempotency_key,
          metadata: {}
        )
      end

      def event_attributes
        attrs = event_payload.to_h.symbolize_keys
        attrs[:source] = attrs[:source].presence || "api"
        attrs[:tokens_in] = attrs[:tokens_in].presence&.to_i
        attrs[:tokens_out] = attrs[:tokens_out].presence&.to_i
        attrs[:cost] = attrs[:cost].presence&.to_d
        attrs
      end

      def validate_usage!(status)
        attrs = event_attributes
        return true if status == "started"
        return true unless ReleaseEvent::USAGE_REQUIRED_SOURCES.include?(attrs[:source].to_s)

        missing = %i[model tokens_in tokens_out cost].select { |key| attrs[key].nil? || attrs[key].to_s.blank? }
        return true if missing.empty?

        render_error(
          "event usage is required for #{attrs[:source]} #{status} events: #{missing.join(', ')}",
          status: :unprocessable_entity,
          error_code: "MISSING_EVENT_USAGE"
        )
        false
      end
    end
  end
end
