# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_bank").to_s

# /dreams: the dream bank as an org chart, and a reading surface for the SOPs each
# soul runs. It reads the tracked files through DreamOrgChart on every request, so a
# merged dream shows without a deploy step.
#
# Several things here are not in the files: Alex McRitchie's one-click approvals
# (DreamApproval) and retirements (DreamRetirement), which wait for a batch task to
# write them into the files; the heat map (DreamHeat), the decisions each dream
# shaped; and the loop (Act 4): sessions' grades (DreamGrade), their swap proposals
# (DreamSwap) and the KPI strip (DreamKpis).
#
# Admin-only, like /agents: AdminWall's default deny covers every action here, and
# `approve`, `retire` and `approve_swap` also require DreamApproval.approver?,
# because an admin seat is not always a human (docs/agents/modules/dream.md, Acts 3-4).
class DreamsController < ApplicationController
  FILTERS = %w[all approved proposed].freeze
  SWAP_ROWS = 10

  def index
    @chart = DreamOrgChart.build
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "all"
    @approvals = DreamApproval.pending_by_key(@chart.dreams)
    @retirements = DreamRetirement.pending_by_key(@chart.dreams)
    @heat = DreamHeat.build
    @grades = DreamGrade.summary
    @kpis = DreamKpis.build(@chart.dreams)
    @swaps = DreamSwap.open.newest.limit(SWAP_ROWS).to_a
    @approver = DreamApproval.approver?(current_user)
  end

  # POST /dreams/approvals — records Alex McRitchie's approval of one proposed dream.
  def approve
    dream = DreamBank.all(dir: DreamBank.bank_dir).find do |candidate|
      candidate.home == params[:dream_home].to_s && candidate.slug == params[:dream_slug].to_s
    end
    DreamApproval.check!(dream, current_user)
    rescue_and_log(target: current_user) { DreamApproval.record!(dream, current_user) }
    redirect_to dreams_path(status: filter_param, anchor: "dream-#{params[:dream_slug]}"),
                notice: "Approved. It loads after the next release.", status: :see_other
  rescue DreamApproval::NotApprovable => e
    redirect_to dreams_path(status: filter_param), alert: "Not approved: #{e.message}.", status: :see_other
  end

  # POST /dreams/retirements — records Alex McRitchie's retirement of one approved dream.
  def retire
    dream = find_dream(params[:dream_home], params[:dream_slug])
    DreamRetirement.check!(dream, current_user)
    rescue_and_log(target: current_user) { DreamRetirement.record!(dream, current_user) }
    redirect_to dreams_path(status: filter_param, anchor: "dream-#{dream.slug}"),
                notice: "Retired. The file goes in the next release.", status: :see_other
  rescue DreamRetirement::NotRetirable => e
    redirect_to dreams_path(status: filter_param), alert: "Not retired: #{e.message}.", status: :see_other
  end

  # POST /dreams/swaps/:id/approval — Alex McRitchie's one click on a session's swap: the in
  # is approved and the out retired, together.
  def approve_swap
    swap = DreamSwap.find(params[:id])
    dreams = DreamBank.all(dir: DreamBank.bank_dir)
    swap.check!(current_user, dreams)
    rescue_and_log(target: current_user) { swap.approve!(current_user, dreams) }
    redirect_to dreams_path(status: filter_param, anchor: "dream-swaps"),
                notice: "Swap approved. It takes effect after the next release.", status: :see_other
  rescue DreamSwap::NotApprovable => e
    redirect_to dreams_path(status: filter_param, anchor: "dream-swaps"), alert: "Swap not approved: #{e.message}.",
                                                                          status: :see_other
  end

  private

  def find_dream(home, slug)
    DreamBank.all(dir: DreamBank.bank_dir).find do |candidate|
      candidate.home == home.to_s && candidate.slug == slug.to_s
    end
  end

  def filter_param = FILTERS.include?(params[:status]) && params[:status] != "all" ? params[:status] : nil
end
