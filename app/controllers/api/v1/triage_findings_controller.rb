module Api
  module V1
    # The agent lane of the triage inbox: FILE and LIST findings. Promotion to a
    # task is deliberately absent — it is the operator's admin-gated web action
    # (TriageController#promote), the same lane split as approval grants.
    class TriageFindingsController < BaseController
      def index
        findings = TriageFinding.recent
        findings = findings.where(status: params[:status]) if params[:status].present?
        result = paginate(findings)
        render_data(result[:records], meta: result[:meta])
      end

      def create
        finding = TriageFinding.new(finding_params)
        rescue_and_log(target: finding) do
          finding.save!
          render_data(finding, status: :created)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      private

      # `prior_art` is permitted but never defaulted here — the column's NOT NULL
      # default ("unknown") owns that, so a caller that omits the field records
      # "nobody looked" rather than silently inheriting a friendlier state. An
      # out-of-range value 422s (model inclusion) instead of being coerced: a
      # prior-art claim the board could not parse must not become a claim it
      # invented. The lane split is untouched — file and list only; promote and
      # dismiss stay admin-gated on the web side.
      def finding_params
        params.permit(:title, :body, :source, :repo, :prior_art, :prior_art_note)
      end
    end
  end
end
