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
    # accepted-but-unrecorded 204 the way the fire-and-forget producers do.
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
      def index
        records = DeskRecord.all
        records = records.for_app(params[:app]) if params[:app].present?
        records = records.where(status: params[:status]) if params[:status].present?
        records = records.where(worktree_path: params[:worktree_path]) if params[:worktree_path].present?
        records = records.open_episodes if ActiveModel::Type::Boolean.new.cast(params[:open])

        result = paginate(records.newest_first)
        render_data(result[:records], meta: result[:meta])
      end

      # File ONE desk record — a `cleanup --write` nomination or a teardown, or an
      # IMPORT of a row stranded in the markdown ledger.
      def create
        # NAMING the field is what makes this an import, not supplying a usable value.
        # Keyed on `present?` a BLANK key fell through to the teardown path below — and
        # that path resolves through `open_for`, which never matches a resolved row, so a
        # keyless import would have duplicated every row on the next run while answering
        # 201 each time. That is the exact defect this endpoint was reviewed for, so it
        # fails LOUD here rather than open: `import!` refuses the blank by name.
        return import if desk_params.key?(:import_key)

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

      # THE IMPORT PATH — /tasks/harvest-stranded-ledger-stashes.
      #
      # It is separate from the teardown path because the two resolve an existing record
      # by DIFFERENT keys, and using the teardown's key here is the bug this endpoint was
      # reviewed for. `DeskRecord.file!` looks up `open_for(worktree_path)`, which matches
      # OPEN episodes only; every stranded row is a RESOLVED `removed` episode, so the
      # lookup never matches and a re-run of the harvest would file all 166 a second time.
      # `import!` keys on the row's own digest instead, which is unique in the schema.
      #
      # 201 for a row this call WROTE, 200 for one the board already held. The harvest
      # counts the two separately, so a second run reports that it wrote nothing rather
      # than claiming successes it did not perform.
      def import
        record = DeskRecord.import!(**import_attributes)
        render_data(record, status: record.previously_new_record? ? :created : :ok)
      rescue ArgumentError => e
        render_error(e.message, error_code: "INVALID_DESK_IMPORT")
      end

      IMPORT_FIELDS = %i[
        worktree_path label app_slug desk_slug task_slug task_url
        reason rationale safe_delete_condition branch head
      ].freeze

      def import_attributes
        attrs = desk_params.to_h.symbolize_keys
        payload = attrs[:payload]
        payload = payload.to_h if payload.respond_to?(:to_h)

        attrs.slice(*IMPORT_FIELDS).compact_blank.merge(
          import_key: attrs[:import_key],
          resolved_on: attrs[:resolved_on],
          payload: payload.is_a?(Hash) ? payload.stringify_keys : {}
        )
      end

      # The narrative fields the SWEEP owns and the registry does not carry: why this
      # desk was safe to take (`reason`), what label that safety wears, and the
      # condition cell the markdown ledger used to print. `compact` so an absent field
      # never blanks a value the registry already supplied.
      OVERRIDE_FIELDS = %i[
        label app_slug desk_slug task_slug task_url source actor
        safety reason rationale withheld_reason safe_delete_condition
      ].freeze

      def overrides
        desk_params.to_h.symbolize_keys.slice(*OVERRIDE_FIELDS).compact_blank
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
          :import_key, :branch, :head,
          registry: {}, payload: {}
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
