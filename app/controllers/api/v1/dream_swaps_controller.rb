require Rails.root.join("bin/lib/dream_bank").to_s

module Api
  module V1
    # The swap half of the dream loop (docs/agents/modules/dream.md, Act 4).
    #
    # GET  /api/v1/dream_swaps/candidates[?layer=<key>]  each layer's room and its
    #      data-ranked out candidates (DreamLoop), for `bin/dream swap-candidates`.
    # POST /api/v1/dream_swaps  a session's one swap proposal, or its "no swap", for
    #      `bin/dream swap`. Proposing is agent work; approving is Alex's alone, on
    #      /dreams, so there is no approve route here.
    class DreamSwapsController < BaseController
      def candidates
        loop = DreamLoop.new(DreamBank.all(dir: DreamBank.bank_dir))
        if params[:layer].present?
          report = loop.report(params[:layer].to_s)
          return render_error("`#{params[:layer]}` is not a layer", status: :not_found, error_code: "NOT_FOUND") unless report

          return render_data([ report.as_json ])
        end
        render_data(loop.reports.map(&:as_json))
      end

      def create
        swap = DreamSwap.propose!(session_id: params[:session_id], reason: params[:reason],
                                  in_key: params[:in].presence, layer: params[:layer], out_key: params[:out].presence,
                                  dreams: DreamBank.all(dir: DreamBank.bank_dir))
        render_data(swap.as_json_row, status: :created)
      rescue DreamSwap::NotProposable => e
        render_error(e.message, status: :unprocessable_entity, error_code: "NOT_PROPOSABLE")
      end
    end
  end
end
