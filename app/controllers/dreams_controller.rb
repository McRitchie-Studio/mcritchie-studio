# frozen_string_literal: true

# /dreams: the dream bank as an org chart, and a reading surface for the SOPs each
# soul runs. Read-only; it reads the tracked files through DreamOrgChart on every
# request, so a merged dream shows without a deploy step or a table.
#
# Admin-only, like /agents: AdminWall's default deny covers every action here.
class DreamsController < ApplicationController
  FILTERS = %w[all approved proposed].freeze

  def index
    @chart = DreamOrgChart.build
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "all"
  end
end
