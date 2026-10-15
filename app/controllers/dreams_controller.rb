# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_bank").to_s

# /dreams: the dream bank as an org chart, and a reading surface for the SOPs each
# soul runs. It reads the tracked files through DreamOrgChart on every request, so a
# merged dream shows without a deploy step.
#
# Two things here are not in the files: Alex's one-click approvals (DreamApproval),
# which wait for a batch task to write them into the files, and the heat map
# (DreamHeat), the decisions each dream shaped.
#
# Admin-only, like /agents: AdminWall's default deny covers every action here, and
# `approve` also requires DreamApproval.approver?, because an admin seat is not
# always a human (docs/agents/modules/dream.md, Act 3).
class DreamsController < ApplicationController
  FILTERS = %w[all approved proposed].freeze

  def index
    @chart = DreamOrgChart.build
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "all"
    @approvals = DreamApproval.pending_by_key(@chart.dreams)
    @heat = DreamHeat.build
    @approver = DreamApproval.approver?(current_user)
  end

  # POST /dreams/approvals — records Alex's approval of one proposed dream.
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

  private

  def filter_param = FILTERS.include?(params[:status]) && params[:status] != "all" ? params[:status] : nil
end
