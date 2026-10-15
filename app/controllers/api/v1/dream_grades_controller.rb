module Api
  module V1
    # POST /api/v1/dream_grades — a session's grade of one dream that fired in it,
    # from `bin/dream grade` at wrap (docs/agents/modules/dream.md, Act 4).
    #
    # Agent-written data, bearer-gated like the other agent writes. A grade never
    # touches a dream's file or status. DreamGrade.record! refuses a dream that did
    # not fire in the named session (no `dream_fired` action there), a second grade
    # of it there, a score outside 0..2, and a grade with no decision.
    class DreamGradesController < BaseController
      def create
        grade = DreamGrade.record!(session_id: params[:session_id], dream_slug: params[:dream_slug],
                                   score: params[:score], decision: params[:decision])
        render_data(grade.slice(:id, :dream_slug, :score, :decision, :session_id, :task_slug, :mascot),
                    status: :created)
      rescue DreamGrade::NotGradable => e
        render_error(e.message, status: :unprocessable_entity, error_code: "NOT_GRADABLE")
      end
    end
  end
end
