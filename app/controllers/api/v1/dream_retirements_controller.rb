require Rails.root.join("bin/lib/dream_bank").to_s

module Api
  module V1
    # GET /api/v1/dream_retirements — the retirements Alex recorded on /dreams whose
    # files the deployed bank still holds, for `bin/dream apply-approvals`, which
    # deletes each file (docs/agents/modules/dream.md, Act 4).
    #
    # Read-only, like dream_approvals: a retirement is Alex's word, given only
    # through DreamsController#retire or #approve_swap, so no agent token makes one.
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
