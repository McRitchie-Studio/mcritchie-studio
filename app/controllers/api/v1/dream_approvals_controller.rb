require Rails.root.join("bin/lib/dream_bank").to_s

module Api
  module V1
    # GET /api/v1/dream_approvals — the dream approvals Alex recorded on /dreams that
    # the files do not carry yet, for `bin/dream approvals` and
    # `bin/dream apply-approvals` (docs/agents/modules/dream.md, Act 3).
    #
    # Read-only, bearer-gated like the other agent reads. There is deliberately no
    # create: an approval is Alex's word, given only through DreamsController#approve
    # behind his signed-in admin session, so no agent token can make one.
    #
    # The read reconciles first: a row whose deployed file already reads approved is
    # stamped applied and drops out. `file_status` is what the deployed file reads.
    class DreamApprovalsController < BaseController
      def index
        dreams = DreamBank.all(dir: DreamBank.bank_dir)
        by_key = dreams.index_by { |dream| DreamApproval.key_for(dream) }
        rows = DreamApproval.pending_by_key(dreams).map { |key, row| row.as_pending_json(by_key[key]) }
        render_data(rows, meta: { count: rows.size })
      end
    end
  end
end
