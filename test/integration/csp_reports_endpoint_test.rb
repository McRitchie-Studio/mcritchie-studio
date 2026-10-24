require "test_helper"

# [integration] hub-report-only-csp: POST /csp_reports stores the browser's CSP
# violation reports (both body shapes), folds repeats into one row, and answers a
# malformed body with a 400, never a 500. /admin/csp_reports lists them for an admin.
class CspReportsEndpointTest < ActionDispatch::IntegrationTest
  REPORT_URI_BODY = {
    "csp-report" => {
      "document-uri" => "https://mcritchie.studio/tasks?filter=open&token=secret#top",
      "violated-directive" => "script-src-elem",
      "effective-directive" => "script-src-elem",
      "blocked-uri" => "inline",
      "source-file" => "https://mcritchie.studio/tasks?x=1",
      "line-number" => 42,
      "script-sample" => "window.evil()",
      "disposition" => "report"
    }
  }.freeze

  def post_report(body, content_type: "application/csp-report")
    post csp_reports_path, params: body.is_a?(String) ? body : body.to_json,
                           headers: { "CONTENT_TYPE" => content_type, "User-Agent" => "Mozilla/5.0 TestBrowser" }
  end

  test "a report-uri report is stored with page, directive, blocked URI and user agent" do
    assert_difference -> { CspReport.count }, 1 do
      post_report(REPORT_URI_BODY)
    end
    assert_response :no_content

    row = CspReport.last
    assert_equal "/tasks", row.document_path, "query and fragment are dropped (a token never lands in the table)"
    assert_equal "script-src-elem", row.directive
    assert_equal "inline", row.blocked_uri
    assert_equal "https://mcritchie.studio/tasks", row.source_file
    assert_equal 42, row.line_number
    assert_equal "window.evil()", row.sample
    assert_equal "Mozilla/5.0 TestBrowser", row.user_agent
    assert_equal 1, row.count
    assert_equal row.first_seen_at, row.last_seen_at
  end

  test "a repeat bumps count and last seen on the same row" do
    post_report(REPORT_URI_BODY)
    first = CspReport.last
    travel 5.minutes do
      assert_no_difference -> { CspReport.count } do
        post_report(REPORT_URI_BODY)
      end
    end
    first.reload
    assert_equal 2, first.count
    assert_operator first.last_seen_at, :>, first.first_seen_at
  end

  test "a Reporting API batch stores each csp-violation and ignores other types" do
    batch = [
      { "type" => "csp-violation", "body" => { "documentURL" => "https://mcritchie.studio/build",
                                               "effectiveDirective" => "connect-src",
                                               "blockedURL" => "https://evil.example/collect?id=7", "disposition" => "report" } },
      { "type" => "deprecation", "body" => { "id" => "x" } }
    ]
    assert_difference -> { CspReport.count }, 1 do
      post_report(batch, content_type: "application/reports+json")
    end
    assert_response :no_content
    row = CspReport.last
    assert_equal [ "/build", "connect-src", "https://evil.example/collect" ], [ row.document_path, row.directive, row.blocked_uri ]
  end

  test "a malformed body answers 400 and stores nothing" do
    assert_no_difference -> { CspReport.count } do
      post_report("{not json")
      assert_response :bad_request
      post_report({ "hello" => "world" })
      assert_response :bad_request
      post_report("[1, 2, 3]")
      assert_response :bad_request
      post_report("")
      assert_response :bad_request
    end
  end

  test "an oversized body is refused" do
    post_report("x" * (CspReportsController::MAX_BODY + 1))
    assert_response :content_too_large
  end

  test "a report naming no page or directive is accepted but not stored" do
    assert_no_difference -> { CspReport.count } do
      post_report({ "csp-report" => { "blocked-uri" => "inline" } })
    end
    assert_response :no_content
  end

  # The suite's cache is a null store, so the limiter never counts; the store's
  # increment is stubbed to answer one past the limit.
  test "past the rate limit a report answers 429 and is not stored" do
    over = ->(*) { 61 }
    CspReportsController.cache_store.stub(:increment, over) do
      assert_no_difference -> { CspReport.count } do
        post_report(REPORT_URI_BODY)
      end
    end
    assert_response :too_many_requests
  end

  test "the admin page lists the top offenders for an admin and is walled for a visitor" do
    CspReport.record!(REPORT_URI_BODY["csp-report"])
    CspReport.record!(REPORT_URI_BODY["csp-report"])
    CspReport.record!({ "documentURL" => "https://mcritchie.studio/", "effectiveDirective" => "img-src", "blockedURL" => "data" })

    get admin_csp_reports_path
    assert_response :redirect

    log_in_as(users(:alex))
    get admin_csp_reports_path
    assert_response :success
    rows = css_select("[data-test=csp-row]")
    assert_equal 2, rows.size
    assert_includes rows.first.text, "script-src-elem", "the most frequent violation leads"
    assert_includes css_select("[data-test=csp-totals]").text, "2 distinct violations · 3 reports"
  end
end
