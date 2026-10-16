require Rails.root.join("bin/lib/dream_bank").to_s

module Api
  module V1
    # POST /api/v1/dream_rulings — Alex's ruling on a dream, given in chat and
    # recorded by the session that heard it, for `bin/dream approve|drop|retire
    # <slug> --clearance "<his words>"` (docs/agents/modules/dream.md, Act 3).
    #
    #   { ruling: approve|drop|retire, dream_home:, dream_slug:, clearance:, session_id: }
    #
    # The one API route that creates an approval or a retirement, and it creates one
    # only on Alex's quoted word: DreamRuling refuses a missing or token clearance
    # and a missing session, and stamps the row via "chat" with both, naming Alex as
    # the approver. It mirrors `bin/release ship --mode cleared --clearance`.
    # 201 for a new row, 200 when the dream already carries that ruling (his click,
    # or an earlier chat ruling), 422 with the reason on a refusal.
    class DreamRulingsController < BaseController
      def create
        dream = DreamBank.all(dir: DreamBank.bank_dir).find do |candidate|
          candidate.home == params[:dream_home].to_s && candidate.slug == params[:dream_slug].to_s
        end
        row, created = DreamRuling.record!(ruling: params[:ruling], dream: dream, clearance: params[:clearance],
                                           session_id: params[:session_id])
        render_data(row_json(row, dream), status: created ? :created : :ok)
      rescue DreamRuling::Refused => e
        render_error(e.message, status: :unprocessable_entity, error_code: "NOT_RULED")
      end

      private

      def row_json(row, dream)
        ruling = row.is_a?(DreamApproval) ? "approve" : row.ruling
        row.as_pending_json(dream).merge(ruling: ruling, created_at: row.created_at&.iso8601)
      end
    end
  end
end
