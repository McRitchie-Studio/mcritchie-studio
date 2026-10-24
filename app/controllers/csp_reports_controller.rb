# POST /csp_reports: the browser's Content-Security-Policy violation reports for
# the hub's report-only policy (config/initializers/content_security_policy.rb
# names this path in report-uri).
# Each report is stored as a CspReport row, read at /admin/csp_reports.
#
# ActionController::Base, not ApplicationController: a browser posts here on its
# own, with no session and no CSRF token, and the app's chain (the admin wall,
# allow_browser, the session check) would answer it with a redirect or a 406.
# Outside the admin wall by construction (AdminWall's header); in
# CsrfSkipAllowlistTest's ALLOWED with the reason.
#
# Two body shapes, so the policy can move to report-to without a change here:
#   report-uri   {"csp-report": {"document-uri": ..., "violated-directive": ...}}
#                (Content-Type application/csp-report)
#   report-to    [{"type": "csp-violation", "body": {"documentURL": ...}}, ...]
#                (Content-Type application/reports+json)
# A body that is not JSON, or JSON of neither shape, answers 400.
class CspReportsController < ActionController::Base
  skip_forgery_protection

  MAX_BODY = 16.kilobytes
  # The Reporting API batches; a batch past this many is truncated, not refused.
  MAX_REPORTS = 10

  rate_limit to: 60, within: 1.minute, with: -> { head :too_many_requests }

  def create
    body = request.body.read(MAX_BODY + 1).to_s
    return head(:content_too_large) if body.bytesize > MAX_BODY

    reports = parse(body)
    return head(:bad_request) if reports.nil?

    reports.first(MAX_REPORTS).each { |report| CspReport.record!(report, user_agent: request.user_agent) }
    head :no_content
  rescue ActiveRecord::ActiveRecordError => e
    # A report is telemetry: a write that fails must not answer the browser with a 500.
    ErrorLog.capture!(e)
    head :no_content
  end

  private

  # The report bodies in the request, or nil when the body is not a report.
  def parse(body)
    parsed = JSON.parse(body)
    reports = case parsed
              when Hash then [ parsed["csp-report"] ]
              when Array then parsed.map { |item| item["body"] if item.is_a?(Hash) && item["type"] == "csp-violation" }
              end
    reports = Array(reports).select { |report| report.is_a?(Hash) }
    reports.presence
  rescue JSON::ParserError
    nil
  end
end
