module Api
  module V1
    class ReleaseNotesController < BaseController
      def create
        payload = release_notes_payload
        task_slugs = normalize_task_slugs(payload["task_slugs"].presence || payload["tasks"])
        return render_error("task_slugs is required", error_code: "MISSING_TASKS") if task_slugs.empty?

        tasks = tasks_for(task_slugs)
        missing = task_slugs - tasks.map(&:slug)
        if missing.any?
          return render_error("Unknown task slug(s): #{missing.join(', ')}", error_code: "UNKNOWN_TASKS")
        end

        message = ReleaseNotes::Formatter.new(
          app: payload["app"],
          environment: payload["environment"],
          release: payload["release"],
          sha: payload["sha"],
          url: payload["url"],
          release_train: payload["release_train"],
          checks: payload["checks"],
          tasks: tasks
        ).message

        delivery = deliver_release_notes(payload, message)

        render_data(
          {
            delivered: delivery.present?,
            dry_run: dry_run?(payload),
            message: message,
            task_slugs: task_slugs
          }
        )
      rescue ReleaseNotes::DiscordClient::MissingWebhook => e
        render_error(e.message, error_code: "MISSING_WEBHOOK")
      rescue ReleaseNotes::DiscordClient::DeliveryError => e
        render_error(e.message, error_code: "DISCORD_DELIVERY_FAILED")
      end

      private

      def release_notes_payload
        params.to_unsafe_h.slice(
          "app",
          "environment",
          "release",
          "sha",
          "url",
          "release_train",
          "checks",
          "task_slugs",
          "tasks",
          "dry_run"
        )
      end

      def normalize_task_slugs(raw)
        Array(raw).flat_map { |value| value.to_s.split(/[\s,]+/) }
                  .map(&:strip)
                  .reject(&:blank?)
                  .uniq
      end

      def tasks_for(task_slugs)
        tasks_by_slug = Task.where(slug: task_slugs).index_by(&:slug)
        task_slugs.filter_map { |slug| tasks_by_slug[slug] }
      end

      def deliver_release_notes(payload, message)
        return nil if dry_run?(payload)

        ReleaseNotes::DiscordClient.deliver(content: message)
      end

      def dry_run?(payload)
        ActiveModel::Type::Boolean.new.cast(payload["dry_run"])
      end
    end
  end
end
