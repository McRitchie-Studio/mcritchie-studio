class AppDevopsStages
  # The app chat's status card, kept current without a reload (task
  # app-card-live-tasks). The card's live half is a turbo-frame
  # (agent_chats/_devops_stages) on a stream per APP, not per viewer: when a task
  # for the app is created, changes stage, moves release or is destroyed (Task),
  # or a release starts or finishes its production deploy (Release), the stream
  # replaces the frame with an empty one whose src is cto_chats#status. Each page
  # listening then fetches its own card as its own viewer, so an owner still gets
  # sanitized titles and an admin links, and nothing viewer-specific crosses the
  # shared stream. AppDevopsChannel admits only a viewer who may manage the app.
  #
  # Every broadcast runs inside Studio::Cable.safe_broadcast: a cable failure
  # never breaks the task or release write that triggered it.
  module Live
    STREAM_PREFIX = "app_devops:".freeze
    APP_SLUG = /\A[a-z0-9-]{1,60}\z/
    CHAT_THREAD = %r{/applications/(?<app>[a-z0-9-]{1,60})/chat\z}
    # A frame reload keeps the BROADCAST frame element and swaps only its
    # children, so it carries the partial's own frame attributes
    # (agent_chats/_devops_stages) or the card loses its spacing on first reload.
    FRAME_ATTRIBUTES = %(target="_top" class="block space-y-3" data-test="devops-board").freeze

    module_function

    def stream_name(app_slug) = "#{STREAM_PREFIX}#{app_slug}"
    def frame_id(app_slug) = "app-devops-#{app_slug}"

    # The app slug a stream name names, or nil when it is not one.
    def parse_stream(name)
      slug = name.to_s.delete_prefix(STREAM_PREFIX)
      name.to_s.start_with?(STREAM_PREFIX) && slug.match?(APP_SLUG) ? slug : nil
    end

    # The apps a task's card shows on: its repos (before and after this write)
    # and the app whose chat opened it.
    def app_slugs_for(task)
      repos = task.devops_repositories
      before = task.previous_changes["metadata"]&.first
      repos += Array(before.is_a?(Hash) ? before.dig("devops", "repositories") : nil)
      thread = task.devops["source_thread"].to_s.match(CHAT_THREAD)
      (repos + [ thread && thread[:app] ]).compact.map(&:to_s).grep(APP_SLUG).uniq
    end

    def task_changed(task)
      Studio::Cable.safe_broadcast { refresh(app_slugs_for(task)) }
    end

    def release_changed(release)
      Studio::Cable.safe_broadcast do
        refresh(release.tasks.where.not(stage: "archived").flat_map { |task| app_slugs_for(task) }.uniq)
      end
    end

    # Tell every card for these apps to reload its frame.
    def refresh(app_slugs)
      helpers = Rails.application.routes.url_helpers
      app_slugs.each do |slug|
        frame = %(<turbo-frame id="#{frame_id(slug)}" #{FRAME_ATTRIBUTES} src="#{helpers.chat_status_application_path(slug)}"></turbo-frame>)
        AppDevopsChannel.broadcast_replace_to(stream_name(slug), target: frame_id(slug), html: frame)
      end
    end
  end
end
