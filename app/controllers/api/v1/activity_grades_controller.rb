module Api
  module V1
    class ActivityGradesController < BaseController
      # The bearer AGENT path for the Alex heartbeat grade-events loop — the
      # first-class alternative to the admin browser drawer. `awaiting` returns the
      # resolved activities still ungraded by Alex; `create` records Alex's grade.
      #
      # SECURITY BOUNDARY: this path ALWAYS grades as `alex` — the grader is never
      # read from params. Mr. McRitchie's audit-OF-Alex (`grader: "mcr"`) stays
      # exclusively the admin browser path, so the shared agent token can never
      # forge the audit-of-Alex ground truth.

      # GET /api/v1/agent_activities/awaiting_grade?limit=N
      #
      # The resolved activities Alex hasn't graded yet, newest-resolved first (capped by
      # the model to 1..MAX_GRADE_BATCH). Each row carries what the grader needs to
      # judge it (id, category, reason, outcome, provenance).
      def awaiting
        activities = AgentActivity.awaiting_grade(grader: ActionGrade::ALEX, limit: batch_limit)
                           .map(&:to_grading_row)
        render_data(activities, meta: { count: activities.size })
      end

      # POST /api/v1/agent_activities/:id/grade
      #
      # Upsert Alex's grade of the activity: { disposition: good|not, slug?, long_form?,
      # intent?: bank|discard }. Returns the recorded grade. A missing activity is a 404;
      # an invalid grade is a 422 (both via BaseController).
      def create
        activity = AgentActivity.find(params[:id])
        grade = record_grade_with_capture(activity)
        render_data(grade.to_grade_json, status: :created)
      end

      private

      # Backend discipline: a failed grade write is captured WITH its activity as
      # context (target linkage), not a bare untargeted 500 via Layer 1. The shared
      # API rescue_and_log keys target_name off #slug, which AgentActivity lacks (only
      # ActionGrade has one) — so link the activity EXPLICITLY here. RecordNotFound /
      # RecordInvalid re-raise for BaseController's clean 404 / 422 (RecordInvalid
      # still logs via :unprocessable, so it's never a bare 500 either).
      def record_grade_with_capture(activity)
        ActionGrade.record_activity_grade(
          activity: activity,
          grader: ActionGrade::ALEX, # forced — never client-supplied
          disposition: grade_params[:disposition],
          slug: grade_params[:slug],
          long_form: grade_params.key?(:long_form) ? grade_params[:long_form] : :unset,
          intent: grade_params[:intent]
        )
      rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
        raise
      rescue StandardError => e
        log = create_error_log(e)
        log.update!(target: activity, target_name: "activity ##{activity.id}")
        @_error_logged = true
        raise e
      end

      def batch_limit
        raw = params[:limit]
        raw.present? ? raw : AgentActivity::DEFAULT_GRADE_BATCH
      end

      def grade_params
        params.permit(:disposition, :slug, :long_form, :intent)
      end
    end
  end
end
