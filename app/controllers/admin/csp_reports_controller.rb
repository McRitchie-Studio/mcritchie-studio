module Admin
  # /admin/csp_reports (Ops → CSP reports): the hub's Content-Security-Policy
  # violations (CspReport), top offenders first, with the window's totals. It is
  # the read the enforce flip is decided from (studio-engine
  # docs/FRONT_END_STANDARD.md, the CSP section). `bin/rails csp:reports` prints
  # the same list.
  class CspReportsController < ApplicationController
    before_action :require_admin

    WINDOWS = { "1" => 1.day, "7" => 7.days, "30" => 30.days }.freeze
    LIMIT = 100

    def index
      @window_key = WINDOWS.key?(params[:days]) ? params[:days] : "7"
      since = WINDOWS.fetch(@window_key).ago
      scope = CspReport.seen_since(since)
      @distinct = scope.count
      @total = scope.sum(:count)
      @reports = scope.top_offenders.limit(LIMIT).to_a
    end
  end
end
