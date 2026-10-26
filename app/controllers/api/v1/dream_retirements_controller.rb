require Rails.root.join("bin/lib/dream_bank").to_s

module Api
  module V1
    # GET /api/v1/dream_retirements — the retirements Alex McRitchie recorded on /dreams whose
    # files the deployed bank still holds, for `bin/dream apply-approvals`, which
    # deletes each file (docs/agents/modules/dream.md, Act 4).
    #
    # Read-only, like dream_approvals: a retirement (or a drop of a proposed dream,
    # `ruling: drop`) is Alex McRitchie's word, given by his click (DreamsController#retire,
    # #approve_swap) or in chat through POST /api/v1/dream_rulings, with his quote.
    # The read reconciles first: a row whose file is gone is stamped applied.
    class DreamRetirementsController < BaseController
      def index
        dreams = DreamBank.all(dir: DreamBank.bank_dir)
        by_key = dreams.index_by { |dream| DreamApproval.key_for(dream) }
        rows = DreamRetirement.pending_by_key(dreams).map { |key, row| row.as_pending_json(by_key[key]) }
        render_data(rows, meta: { count: rows.size })
      end
    end
  end
end
