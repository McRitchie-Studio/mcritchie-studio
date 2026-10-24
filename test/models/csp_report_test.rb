require "test_helper"

# [unit] hub-report-only-csp: CspReport normalizes a browser report (either shape),
# keys it by its fingerprint, and keeps a query-string token out of every column.
class CspReportTest < ActiveSupport::TestCase
  test "normalize reads report-uri and Reporting API keys alike" do
    legacy = CspReport.normalize("document-uri" => "https://h.test/a?b=1", "violated-directive" => "script-src-elem 'self'",
                                 "blocked-uri" => "eval", "line-number" => "7")
    modern = CspReport.normalize("documentURL" => "https://h.test/a#x", "effectiveDirective" => "script-src-elem",
                                 "blockedURL" => "eval", "lineNumber" => 7)
    assert_equal legacy, modern
    assert_equal({ document_path: "/a", directive: "script-src-elem", blocked_uri: "eval", source_file: nil,
                   line_number: 7, sample: nil, disposition: nil }, legacy)
  end

  test "a blocked URL keeps origin and path only, and long fields are capped" do
    attrs = CspReport.normalize("documentURL" => "https://h.test/#{'p' * 400}", "effectiveDirective" => "img-src",
                                "blockedURL" => "https://cdn.example/x.js?token=abc")
    assert_equal "https://cdn.example/x.js", attrs[:blocked_uri]
    assert_equal CspReport::MAX_FIELD, attrs[:document_path].size
  end

  test "different source lines on one page are different rows" do
    base = { "documentURL" => "https://h.test/", "effectiveDirective" => "script-src-elem", "blockedURL" => "inline" }
    a = CspReport.record!(base.merge("lineNumber" => 1))
    b = CspReport.record!(base.merge("lineNumber" => 2))
    refute_equal a.id, b.id
  end

  test "retention deletes rows not seen for 30 days and keeps the rest" do
    now = Time.current
    old = CspReport.record!({ "documentURL" => "https://h.test/old", "effectiveDirective" => "img-src", "blockedURL" => "data" },
                            now: now - 31.days)
    fresh = CspReport.record!({ "documentURL" => "https://h.test/new", "effectiveDirective" => "img-src", "blockedURL" => "data" },
                              now: now - 29.days)
    assert_equal 1, CspReportRetentionJob.perform_now(now: now)
    refute CspReport.exists?(old.id)
    assert CspReport.exists?(fresh.id)
  end

  test "the retention job is scheduled nightly in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "csp_report_retention")
    assert_equal "CspReportRetentionJob", entry&.fetch("class")
  end
end
