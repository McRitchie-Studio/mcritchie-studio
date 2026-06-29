module Api
  module V1
    class ReviewEventsController < BaseController
      before_action :set_task

      def create
        attrs = event_attributes
        return unless validate_usage!(attrs)

        event = nil
        rescue_and_log(target: @task) do
          event = with_task_event_context(attrs) do
            @task.record_review_check_in(
              role: attrs[:role],
              moment: attrs[:moment],
              status: attrs[:status],
              actor: attrs[:actor],
              source: attrs[:source],
              message: attrs[:message],
              idempotency_key: attrs[:idempotency_key],
              metadata: attrs[:metadata]
            )
          end
        end
        render_data(review_event_json(event), status: :created)
      rescue StandardError => e
        render_error(e.message)
      end

      private

      def set_task
        @task = Task.find_by(slug: params[:slug])
        return if @task

        render_error("task not found", status: :not_found, error_code: "NOT_FOUND")
      end

      def event_payload
        raw = params[:review_event]
        raw = params[:event] unless raw.is_a?(ActionController::Parameters)
        raw = params unless raw.is_a?(ActionController::Parameters)
        raw.permit(
          :role, :review_role, :moment, :review_moment, :status, :actor, :source,
          :message, :idempotency_key, :model, :tokens_in, :tokens_out, :cost,
          metadata: {}
        )
      end

      def event_attributes
        attrs = event_payload.to_h.symbolize_keys
        attrs[:role] = attrs[:role].presence || attrs[:review_role].presence
        attrs[:moment] = attrs[:moment].presence || attrs[:review_moment].presence
        attrs[:source] = attrs[:source].presence || "api"
        attrs[:tokens_in] = attrs[:tokens_in].presence&.to_i
        attrs[:tokens_out] = attrs[:tokens_out].presence&.to_i
        attrs[:cost] = attrs[:cost].presence&.to_d
        attrs[:metadata] ||= {}
        attrs[:status] = attrs[:status].presence || default_status_for(attrs[:moment])
        attrs
      end

      def default_status_for(moment)
        case Task.normalize_review_moment(moment)
        when "started" then "started"
        when "completed" then "completed"
        when "failed" then "failed"
        else "info"
        end
      end

      def validate_usage!(attrs)
        return true unless %w[api agent cli].include?(attrs[:source].to_s)
        return true unless %w[completed failed].include?(attrs[:status].to_s)

        missing = %i[model tokens_in tokens_out cost].select { |key| attrs[key].nil? || attrs[key].to_s.blank? }
        return true if missing.empty?

        render_error(
          "event usage is required for #{attrs[:source]} #{attrs[:status]} review events: #{missing.join(', ')}",
          status: :unprocessable_entity,
          error_code: "MISSING_EVENT_USAGE"
        )
        false
      end

      def with_task_event_context(attrs)
        Current.task_event_source = attrs[:source]
        Current.task_event_actor = attrs[:actor].presence
        Current.task_event_model = attrs[:model].presence
        Current.task_event_tokens_in = attrs[:tokens_in]
        Current.task_event_tokens_out = attrs[:tokens_out]
        Current.task_event_cost = attrs[:cost]
        yield
      ensure
        Current.task_event_source = nil
        Current.task_event_actor = nil
        Current.task_event_model = nil
        Current.task_event_tokens_in = nil
        Current.task_event_tokens_out = nil
        Current.task_event_cost = nil
      end

      def review_event_json(event)
        event.as_json.merge(
          "review_role" => event.review_role,
          "review_moment" => event.review_moment,
          "review_status" => event.review_status,
          "review_moment_label" => event.review_moment_label
        )
      end
    end
  end
end
