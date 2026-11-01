module Api
  module V1
    # Desk-ledger writes — the audit row `bin/agent-worktree` files when it nominates or
    # tears down a worktree desk.
    #
    # THIS ENDPOINT IS ON THE DESTROY PATH. `bin/agent-worktree` posts here BEFORE it
    # stops a stack or drops a git worktree, and it FAILS CLOSED on anything but a 2xx:
    # no desk is destroyed without a durable record already committed. So a non-2xx here
    # is not a dropped telemetry beat, it is a REFUSED TEARDOWN — which is the posture we
    # want, and the reason this controller never degrades a failed write into an
    # accepted-but-unrecorded 204 the way the fire-and-forget producers do. That is the
    # teardown's FIRST (`removing`) write. Its closing `removed`/`leaked` write lands after
    # the desk is gone, so the CLI only warns when that one fails.
    #
    # THE CALLER POSTS THE REGISTRY RECORD VERBATIM, not a hand-mapped set of columns.
    # `bin/agent-worktree snapshot` already builds exactly this hash
    # (stack_record_snapshot), and DeskRecord.registry_attributes is the ONE place it is
    # mapped onto columns — so the single-desk post and the bulk sync can never produce
    # two different accounts of the same desk, and a new registry field reaches the board
    # by being added in one file rather than three.
    #
    # All writes flow through DeskRecord's own funnel (file!/sync!) so the episode
    # semantics — a resolved row is history, a recycled desk path opens a NEW episode —
    # live in the model, exactly as GateRun keeps attempt semantics there.
    class DeskRecordsController < BaseController
      # A harness key reads the board here (agent-sessions-design.md, section 2).
      accepts_harness_key :index

      def index
        records = DeskRecord.all
        records = records.for_app(params[:app]) if params[:app].present?
        records = records.where(status: params[:status]) if params[:status].present?
        records = records.where(worktree_path: params[:worktree_path]) if params[:worktree_path].present?
        records = records.open_episodes if ActiveModel::Type::Boolean.new.cast(params[:open])

        result = paginate(records.newest_first)
        render_data(result[:records], meta: result[:meta])
      end

      # File ONE desk record — a `cleanup --write` nomination or a teardown.
      def create
        # THE LEDGER IMPORT IS RETIRED, AND AN OLD CLIENT IS REFUSED BY NAME. The harvest ran
        # on 2026-11-01. A stale copy of it that reached the teardown path below would file
        # every row again, because `file!` resolves only OPEN episodes and answers 201 each
        # time. So naming the field is still enough to stop the write here.
        return render_error("the desk ledger import is retired", status: :gone, error_code: "DESK_IMPORT_RETIRED") if desk_params.key?(:import_key)

        attrs = registry_attributes
        path = (desk_params[:worktree_path].presence || attrs[:worktree_path]).to_s
        return render_error("worktree_path is required", error_code: "MISSING_WORKTREE_PATH") if path.blank?

        status = desk_params[:status].presence || "live"
        unless DeskRecord::STATUSES.include?(status)
          return render_error("unknown status #{status.inspect} (one of: #{DeskRecord::STATUSES.join(', ')})",
                              error_code: "INVALID_DESK_STATUS")
        end

        record = DeskRecord.file!(**attrs.merge(overrides),
                                  worktree_path: path,
                                  status: status,
                                  resolved_on: desk_params[:resolved_on].presence)
        render_data(record, status: :created)
      rescue ActiveRecord::RecordInvalid => e
        # A write the model refuses, such as a `leaked` close that names no process. The open
        # episode is untouched, and the poster needs the reason, not a 500.
        render_error(e.record.errors.full_messages.to_sentence, error_code: "INVALID_DESK_RECORD")
      rescue DeskRecord::ResolvedRecordImmutable => e
        # A caller trying to rewrite history is a BUG in the writer, not a bad request
        # that would pass on retry — say so in its own error_code and status rather than
        # letting it render as a generic validation failure the poster will retry twice.
        create_error_log(e)
        render_error(e.message, status: :conflict, error_code: "RESOLVED_RECORD_IMMUTABLE")
      end

      # Fold a whole `bin/agent-worktree snapshot --write` registry in: every desk it
      # lists is seen, and the run's capacity + summary become a DeskSnapshot.
      def sync
        payload = registry_payload
        return render_error("registry payload is required", error_code: "MISSING_REGISTRY") if payload.blank?

        snapshot = DeskRecord.sync!(payload)
        render_data({
                      snapshot: snapshot,
                      desks: snapshot.desk_count,
                      vanished: DeskRecord.vanished.count
                    }, status: :created)
      end

      private

      # The narrative fields the SWEEP owns and the registry does not carry: why this
      # desk was safe to take (`reason`), what label that safety wears, and the
      # condition cell the markdown ledger used to print. `compact` so an absent field
      # never blanks a value the registry already supplied. `leaked_processes` is the
      # teardown's own evidence: the processes it spared on a `leaked` close.
      OVERRIDE_FIELDS = %i[
        label app_slug desk_slug task_slug task_url source actor
        safety reason rationale withheld_reason safe_delete_condition
        leaked_processes
      ].freeze

      # The session's soul is the actor when a session is present (the param is ignored).
      def overrides
        fields = desk_params.to_h.symbolize_keys.slice(*OVERRIDE_FIELDS)
        fields[:actor] = session_actor(fields[:actor])
        fields.compact_blank
      end

      def registry_attributes
        record = desk_params[:registry]
        record = record.to_h if record.respond_to?(:to_h)
        return {} unless record.is_a?(Hash) && record.present?

        DeskRecord.registry_attributes(record.stringify_keys)
      end

      def desk_params
        raw = params[:desk]
        raw = params unless raw.is_a?(ActionController::Parameters)
        @desk_params ||= raw.permit(
          :worktree_path, :status, :resolved_on, :source, :actor,
          :label, :app_slug, :desk_slug, :task_slug, :task_url,
          :safety, :reason, :rationale, :withheld_reason, :safe_delete_condition,
          :import_key,
          registry: {}, payload: {}, leaked_processes: %i[pid label via port cwd]
        )
      end

      # The registry as posted. `params[:registry]` is the documented shape; a bare body
      # is accepted too, because a poster that JSON-dumps the registry file verbatim is
      # the obvious thing to write and refusing it would be a papercut with no safety
      # value — `worktrees` is what sync! reads either way.
      def registry_payload
        raw = params[:registry]
        raw = params unless raw.is_a?(ActionController::Parameters)
        return nil unless raw[:worktrees].present? || raw[:generated_at].present?

        raw.permit!.to_h
      end
    end
  end
end
