module Api
  module V1
    class EventGradesController < BaseController
      # The bearer AGENT path for the Alex heartbeat grade-events loop — the
      # first-class alternative to the admin browser drawer. `awaiting` returns the
      # resolved spans still ungraded by Alex; `create` records Alex's grade of one.
      #
      # SECURITY BOUNDARY: this path ALWAYS grades as `alex` — the grader is never
      # read from params. Mr. McRitchie's audit-OF-Alex (`grader: "mcr"`) stays
      # exclusively the admin browser path, so the shared agent token can never
      # forge the audit-of-Alex ground truth.

      # GET /api/v1/atomic_events/awaiting_grade?limit=N
      #
      # The resolved spans Alex hasn't graded yet, newest-resolved first (capped by
      # the model to 1..MAX_GRADE_BATCH). Each row carries what the grader needs to
      # judge it (id, category, reason, outcome, provenance).
      def awaiting
        spans = AtomicEvent.awaiting_grade(grader: ActionGrade::ALEX, limit: batch_limit)
                           .map(&:to_grading_row)
        render_data(spans, meta: { count: spans.size })
      end

      # POST /api/v1/atomic_events/:id/grade
      #
      # Upsert Alex's grade of the span: { disposition: good|not, slug?, long_form?,
      # intent?: bank|discard }. Returns the recorded grade. A missing span is a 404;
      # an invalid grade is a 422 (both via BaseController).
      def create
        event = AtomicEvent.find(params[:id])
        grade = record_grade_with_capture(event)
        render_data(grade.to_grade_json, status: :created)
      end

      private

      # Backend discipline: a failed grade write is captured WITH its span as
      # context (target linkage), not a bare untargeted 500 via Layer 1. The shared
      # API rescue_and_log keys target_name off #slug, which AtomicEvent lacks (only
      # ActionGrade has one) — so link the span EXPLICITLY here. RecordNotFound /
      # RecordInvalid re-raise for BaseController's clean 404 / 422 (RecordInvalid
      # still logs via :unprocessable, so it's never a bare 500 either).
      def record_grade_with_capture(event)
        ActionGrade.record_event_grade(
          event: event,
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
        log.update!(target: event, target_name: "span ##{event.id}")
        @_error_logged = true
        raise e
      end

      def batch_limit
        raw = params[:limit]
        raw.present? ? raw : AtomicEvent::DEFAULT_GRADE_BATCH
      end

      def grade_params
        params.permit(:disposition, :slug, :long_form, :intent)
      end
    end
  end
end
