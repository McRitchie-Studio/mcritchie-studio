# The hub's CSP violation reports (CspReport), for a terminal:
#
#   bin/rails csp:reports            # top 25 offenders, last 7 days
#   DAYS=30 LIMIT=50 bin/rails csp:reports
#
# The same list is at /admin/csp_reports.
namespace :csp do
  desc "List the top CSP violation reports (DAYS=7, LIMIT=25)"
  task reports: :environment do
    days = ENV.fetch("DAYS", "7").to_i.clamp(1, 30)
    limit = ENV.fetch("LIMIT", "25").to_i.clamp(1, 500)
    scope = CspReport.seen_since(days.days.ago)
    puts "CSP reports, last #{days} day(s): #{scope.count} distinct, #{scope.sum(:count)} total"
    scope.top_offenders.limit(limit).each do |report|
      source = [ report.source_file, report.line_number ].compact.join(":")
      puts format("%7d  %-18s %-40s %s%s", report.count, report.directive, report.blocked_uri[0, 40],
                  report.document_path, source.empty? ? "" : "  (#{source})")
    end
  end
end
