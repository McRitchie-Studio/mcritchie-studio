module Api
  module V1
    class TasksController < BaseController
      # The filter/query params `GET /api/v1/tasks` understands. Anything else is
      # rejected with a 400 rather than silently ignored — a `?status=submitted`
      # used to fall through to "no filter" and return EVERY task (the param is
      # `stage`, not `status`). `page`/`per_page` are read by Api::Paginatable.
      INDEX_PARAMS = %w[stage agent_slug reviewable page per_page].freeze

      before_action :capture_task_event_context, only: [:create, :update, :intent, :block]
      before_action :set_task, only: [:show, :update, :destroy, :intent, :block]

      def index
        return if reject_unsupported_index_params!

        tasks = Task.recent
        tasks = tasks.by_stage(params[:stage]) if params[:stage].present?
        tasks = tasks.where(agent_slug: params[:agent_slug]) if params[:agent_slug].present?
        # `reviewable=1` narrows to submitted tasks NOT already under live review —
        # the per-task-review-claim query many parallel pr-review sessions poll. It
        # already implies stage=submitted (Task.reviewable folds it in), so it works
        # with or without an explicit `stage=submitted`.
        tasks = tasks.merge(Task.reviewable) if ActiveModel::Type::Boolean.new.cast(params[:reviewable])
        result = paginate(tasks)
        render_data(result[:records], meta: result[:meta])
      end

      def show
        render_data(task_json(@task))
      end

      def create
        task = Task.new(task_params)
        rescue_and_log(target: task) do
          task.save!
          render_data(task, status: :created)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      def update
        rescue_and_log(target: @task) do
          @task.update!(task_params)
          render_data(@task)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      def destroy
        rescue_and_log(target: @task) do
          @task.destroy!
          head :no_content
        end
      rescue StandardError => e
        render_error(e.message)
      end

      # Record an INTENT event: an agent (or the two-senior review pair) STARTING
      # the work that will produce `to_stage`, so the board/timeline can show who's
      # on it with a live ticker BEFORE the transition lands. Append-only +
      # idempotent (an identical open intent in the current source-stage cycle is
      # reused), and a no-op once the transition has landed in that cycle — so a
      # retry never stacks rows, while a reworked task can be reviewed again after
      # resubmission.
      def intent
        to_stage = params[:to_stage].to_s.strip
        if to_stage.blank?
          return render_error("to_stage is required", status: :bad_request, error_code: "MISSING_PARAM")
        end

        reviewers = Array(params[:reviewers]).map { |r| r.respond_to?(:to_unsafe_h) ? r.to_unsafe_h : r }
        rescue_and_log(target: @task) do
          @task.record_intent_event(to_stage: to_stage, actor: params[:actor].presence, reviewers: reviewers)
          render_data(@task)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      # Mark the task blocked WITHOUT leaving the pipeline — a `building` attribute
      # (blocked_at + blocked_from + blocked_by + block_kind), server-enforced via
      # Task#block! so blocked_from is derived, not caller-supplied. `by` names the
      # blocking agent (defaults to the event actor); `kind` is the block_kind.
      # This is the CLI/agent path (bin/task block). The prose feedback rides as a
      # separate qa_feedback Activity the caller posts alongside.
      def block
        rescue_and_log(target: @task) do
          @task.block!(by: params[:by].presence || Current.task_event_actor.presence,
                       kind: params[:kind].presence)
          render_data(@task)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      private

      # Guarded lookup so a missing slug returns a clean 404 with a JSON error
      # body, never a 500. (The base controller's rescue_from RecordNotFound is the
      # systemic backstop; this gives the tasks endpoints a task-specific message.)
      def set_task
        @task = Task.find_by(slug: params[:slug])
        return if @task

        render_error("task not found", status: :not_found, error_code: "NOT_FOUND")
      end

      def task_json(task)
        task.as_json.merge(
          # Override the raw gates column with the self-healing read — a stale
          # version (or a pre-backfill row) rebuilds live from gate_runs instead
          # of serving `{}`. Index keeps the raw column (no per-row rebuild cost).
          "gates" => Task::GatesProjection.cached_or_built(task),
          "latest_activity" => latest_activity_json(task),
          "unresolved_feedback" => activity_json(task.unresolved_feedback_activity),
          "review_in_progress" => task.review_in_progress?,
          # The progress fact, beside the liveness fact. The claim gate in bin/task
          # reads these to tell a second agent what the holder has actually DONE
          # ("last progress 28m ago · cert failed"), not merely that its terminal
          # is painting. nil = unknown, which must always read as healthy.
          "last_progress_at" => task.last_progress_at,
          "last_progress_label" => task.last_progress_label,
          "progress_seconds_ago" => task.progress_seconds_ago,
          "progress_quiet" => task.claim_progress_quiet?,
          # WHOSE progress, and specifically the HOLDER's. The fields above say
          # what landed on the task; they cannot say whether the holder is the one
          # who landed it, and the claim gate used to assume it was — quoting a
          # challenger's own cert back to it as proof the holder was alive. nil in
          # any of these three means UNKNOWN and is rendered as unknown.
          "last_progress_actor" => task.last_progress_actor,
          "holder_progress_label" => task.holder_progress_label,
          "holder_progress_seconds_ago" => task.holder_progress_seconds_ago,
          # A cert writes nothing into its desk while it runs (measured g1_cert p99:
          # 94 minutes), so the heartbeat needs this channel to tell a long green
          # cert apart from a walked-away terminal. Already computed for
          # progress_quiet; published so the lease decision can read it too.
          "gate_in_flight" => task.gate_in_flight?,
          # The two facts the LEASE decision reads. Their task-wide twins above
          # describe the task; only these describe the HOLDER, and a challenger
          # that certifies a held slug moves the task-wide pair while saying
          # nothing about whether the holder is still there. An artifact counts
          # here unless it is demonstrably another session's, so every unknown
          # still keeps the desk.
          "holder_liveness_seconds_ago" => task.holder_liveness_seconds_ago,
          "holder_gate_in_flight" => task.holder_gate_in_flight?
        )
      end

      def latest_activity_json(task)
        Activity.for_task(task.slug)
                .where(activity_type: Activity::TASK_CONVERSATION_TYPES)
                .recent
                .first
                &.as_json
      end

      def activity_json(activity)
        activity&.as_json
      end

      # Reject query params the index doesn't support instead of silently ignoring
      # them (a silent ignore on a filter param returns ALL tasks — a footgun). The
      # most common slip is `status` for `stage`, so hint toward it. Returns true
      # when it rendered an error, so the caller can halt.
      def reject_unsupported_index_params!
        unknown = request.query_parameters.keys.map(&:to_s) - INDEX_PARAMS
        return false if unknown.empty?

        hint = unknown.include?("status") ? " (did you mean 'stage'?)" : ""
        render_error(
          "unsupported query param(s): #{unknown.join(', ')}#{hint}. supported: #{INDEX_PARAMS.join(', ')}",
          status: :bad_request,
          error_code: "UNSUPPORTED_PARAM"
        )
        true
      end

      # Drain an optional `event` payload into Current so Task#write_stage_event
      # can annotate the transition it's about to write with the agent-reported,
      # per-transition usage. The deterministic from/to/duration spine is recorded
      # regardless; this only adds model/tokens/cost when the caller supplies them.
      def capture_task_event_context
        event = params[:event]
        # `event` is only a hash payload when nested params arrive as
        # ActionController::Parameters. A scalar (`?event=foo`) or array comes
        # through as String/Array — symbol-indexing those raises TypeError in the
        # before_action — so treat anything that isn't Parameters as "no payload".
        event = nil unless event.is_a?(ActionController::Parameters)
        Current.task_event_source = sanitized_task_event_source(event)
        return if event.blank?

        Current.task_event_actor      = event[:actor].presence
        Current.task_event_model      = event[:model].presence
        Current.task_event_tokens_in  = event[:tokens_in].presence&.to_i
        Current.task_event_tokens_out = event[:tokens_out].presence&.to_i
        Current.task_event_cost       = event[:cost].presence&.to_d
        # The un-folded cache buckets bin/task now sends. Task#task_event_usage re-derives
        # the event's cost from these SERVER-side, so an operator's rate override applies;
        # the caller's `cost` above is only the fallback when they're absent.
        Current.task_event_cache_creation_tokens = event[:cache_creation_tokens].presence&.to_i
        Current.task_event_cache_read_tokens     = event[:cache_read_tokens].presence&.to_i
      end

      # The bearer API is definitionally the AGENT lane: its writes are "api"
      # (default) or "cli" (bin/task). It must NEVER claim an OPERATOR source
      # (Task::OPERATOR_APPROVAL_GRANT_SOURCES, e.g. "web") via the request body —
      # "web" is stamped only server-side by the admin-gated TasksController#update,
      # behind require_admin. This is ATTRIBUTION, not authorization: the source
      # rides onto every TaskEvent the write records (Task#write_stage_event and
      # #record_intent_event both read Current.task_event_source), so a PATCH carrying
      # {"event":{"source":"web"}} would otherwise write agent activity into the
      # trail wearing the operator's name. Clamp a caller-supplied operator source
      # back to "api" so the lane is derived from the AUTHENTICATED channel, not
      # from caller-supplied data. Legitimate agent sources pass through.
      def sanitized_task_event_source(event)
        source = (event && event[:source].presence) || "api"
        return "api" if Task::OPERATOR_APPROVAL_GRANT_SOURCES.include?(source)

        source
      end

      def task_params
        permitted = params.permit(
          :slug, # honored only on create (attr_readonly on the model); custom readable handle
          :title,
          :description,
          :priority,
          :agent_slug,
          :stage,
          # The size trio (po/dev are forecasts; actual is measured). bin/task sets
          # po/dev/pm via --*-size on create/update + --dev-size on the building
          # claim; actual_size is normally auto-derived at ship but stays settable
          # for a manual override (mirrors the /sizing admin editor). The model
          # validates each against SIZES.
          :pm_size,
          :po_size,
          :dev_size,
          :actual_size,
          # The git-location crash-recovery signal (nil/accepted/release/main —
          # Task::MERGED_STATES). Review stamps "accepted" via `bin/task merged`
          # when it lands a feat PR on the accepted branch; the model validates it.
          # Set through the same one-path PATCH update as `stage` (no named-transition
          # endpoint — see config/routes.rb).
          :merged,
          # The `backend_migration` exclusive-lane flag (exclusive-lanes.md). The
          # SOP has always told a backend Dev to SELF-FLAG the moment they realize
          # they need a migration — "update the flag, acquire the lane, then write
          # the migration file" — while this permit list left `requires_migration`
          # writable ONLY through the admin-gated /sizing editor, so no agent could
          # carry out the instruction. Permitting it here widens the writers from
          # admin-only to any bearer-token agent, which is the point: the flag is a
          # DevOps signal like the size trio beside it, not an authorization
          # boundary. The lane's mutual exclusion lives in MigrationLaneClaim, and
          # is not weakened by anyone flipping this boolean.
          :requires_migration,
          required_skills: [],
          metadata: {}
        )
        attrs = permitted.except(:devops).to_h
        # slug is honored only on create; on update params[:slug] is the URL id and
        # assigning it would trip attr_readonly. Drop it so updates never touch slug.
        attrs.delete("slug") unless action_name == "create"
        return attrs unless params[:devops]

        attrs["metadata"] = attrs.fetch("metadata", {}).to_h.merge(
          "devops" => Task.normalize_devops_metadata(raw_devops_params)
        )
        attrs
      end

      def raw_devops_params
        raw = params[:devops]
        raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      end
    end
  end
end
