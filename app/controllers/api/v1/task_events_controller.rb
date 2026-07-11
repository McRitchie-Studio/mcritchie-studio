module Api
  module V1
    class TaskEventsController < BaseController
      STAGE_ALIASES = {
        "design" => "designed",
        "design_complete" => "designed",
        "heavy_review" => "reviewed",
        "light_review" => "reviewed",
        "review" => "reviewed"
      }.freeze
      REVIEW_WEIGHTS = {
        "heavy_review" => "primary",
        "light_review" => "light"
      }.freeze

      before_action :set_task

      def start
        event =
          if transition_intent_stage?
            @task.record_intent_event(
              to_stage: normalized_stage,
              actor: event_attributes[:actor],
              reviewers: reviewers_for_alias,
              source: event_attributes[:source]
            )
          end
        event ||= @task.record_checkpoint_event(
          name: raw_stage,
          status: "started",
          actor: event_attributes[:actor],
          source: event_attributes[:source],
          metadata: checkpoint_metadata
        )
        render_data(event, status: :created)
      rescue StandardError => e
        render_error(e.message)
      end

      def complete
        return unless validate_usage!("completed")

        event = with_task_event_context do
          if transition_stage?
            @task.update!(stage: normalized_stage)
            @task.task_events.chronological.last
          else
            @task.record_checkpoint_event(
              name: raw_stage,
              status: "completed",
              actor: event_attributes[:actor],
              source: event_attributes[:source],
              metadata: checkpoint_metadata
            )
          end
        end
        render_data(event, status: :created)
      rescue StandardError => e
        render_error(e.message)
      end

      def fail
        return unless validate_usage!("failed")

        event = Task.transaction do
          checkpoint = @task.record_checkpoint_event(
            name: raw_stage,
            status: "failed",
            actor: event_attributes[:actor],
            source: event_attributes[:source],
            metadata: checkpoint_metadata
          )
          with_task_event_context do
            @task.block!(by: event_attributes[:actor], kind: params[:kind].presence || "rework")
          end
          checkpoint
        end
        render_data(event, status: :created)
      rescue StandardError => e
        render_error(e.message)
      end

      private

      def set_task
        @task = Task.find_by(slug: params[:slug])
        return if @task

        render_error("task not found", status: :not_found, error_code: "NOT_FOUND")
      end

      def raw_stage
        params[:stage].to_s.strip
      end

      def normalized_stage
        STAGE_ALIASES.fetch(raw_stage, raw_stage)
      end

      def transition_intent_stage?
        Task::STAGES.include?(normalized_stage) && Task::NEXT_INTENT_STAGE[@task.stage] == normalized_stage
      end

      def transition_stage?
        Task::STAGES.include?(normalized_stage) && @task.stage != normalized_stage && !review_alias?
      end

      def review_alias?
        REVIEW_WEIGHTS.key?(raw_stage)
      end

      def reviewers_for_alias
        weight = REVIEW_WEIGHTS[raw_stage]
        return event_reviewers if weight.blank?

        slug = event_attributes[:actor].presence
        return event_reviewers if slug.blank?

        [{ "slug" => slug, "weight" => weight }]
      end

      def checkpoint_metadata
        metadata = event_attributes[:metadata].to_h.merge(
          "stage" => normalized_stage,
          "event" => raw_stage
        )
        metadata["message"] = event_attributes[:message].to_s.strip if event_attributes[:message].present?
        metadata["idempotency_key"] = event_attributes[:idempotency_key].to_s.strip if event_attributes[:idempotency_key].present?
        metadata
      end

      def event_payload
        raw = params[:event]
        raw = params unless raw.is_a?(ActionController::Parameters)
        raw.permit(
          :source, :actor, :model, :tokens_in, :tokens_out, :cost, :message,
          :idempotency_key,
          metadata: {},
          reviewers: %i[slug weight agent_slug review_weight depth]
        )
      end

      def event_attributes
        attrs = event_payload.to_h.symbolize_keys
        attrs[:source] = attrs[:source].presence || "api"
        attrs[:tokens_in] = attrs[:tokens_in].presence&.to_i
        attrs[:tokens_out] = attrs[:tokens_out].presence&.to_i
        attrs[:cost] = attrs[:cost].presence&.to_d
        attrs[:metadata] ||= {}
        attrs
      end

      def event_reviewers
        raw = event_payload[:reviewers]
        return nil if raw.blank?

        Array(raw).map { |item| item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item }
      end

      def validate_usage!(status)
        attrs = event_attributes
        return true unless %w[api agent cli].include?(attrs[:source].to_s)

        missing = %i[model tokens_in tokens_out cost].select { |key| attrs[key].nil? || attrs[key].to_s.blank? }
        return true if missing.empty?

        render_error(
          "event usage is required for #{attrs[:source]} #{status} events: #{missing.join(', ')}",
          status: :unprocessable_entity,
          error_code: "MISSING_EVENT_USAGE"
        )
        false
      end

      def with_task_event_context
        attrs = event_attributes
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
    end
  end
end
