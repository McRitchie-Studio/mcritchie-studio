# frozen_string_literal: true

# bin/triage — the triage-inbox CLI.
#
# Covered here because `bin/release retro` now depends on `list --json` to decide
# whether a follow-up is already open. That guard is only as good as the read
# behind it, and the read has TWO ways to silently under-report:
#
#   1. the human `list` output drops the BODY, so a caller matching on title+body
#      cannot use it — hence --json; and
#   2. Api::Paginatable caps per_page at 100 while the open inbox already holds
#      ~86, so a single-page read goes blind past the cap with NO error. A guard
#      that stops guarding at 101 findings, quietly, is exactly the failure mode
#      the retro fix exists to prevent — so the paging is asserted, not assumed.
#
# Stub-server shape borrowed from test/lib/task_cli_test.rb.

require "minitest/autorun"
require "open3"
require "json"
require "socket"
require_relative "../support/session_env"

class TriageCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/triage", __dir__)

  # Serve `pages` (an array of row-arrays) as successive pages of
  # GET /api/v1/triage_findings, recording every request path. Returns
  # [requests, stdout, stderr, status].
  def run_triage(*args, pages: [[]])
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, pages) }

    env = SessionEnv.neutralized(
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, pages)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      len = headers["content-length"]
      body = len ? client.read(len.to_i) : ""
      requests << { method: method, path: path, body: body }

      status, payload = response_for(path, pages)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def response_for(path, pages)
    return ["200 OK", JSON.generate("token" => "stub-token")] if path == "/api/v1/auth"

    page = (path[/[?&]page=(\d+)/, 1] || "1").to_i
    rows = pages[page - 1] || []
    ["200 OK", JSON.generate("data" => rows,
                             "meta" => { "page" => page, "per_page" => 100,
                                         "total_pages" => pages.size, "total" => pages.sum(&:size) })]
  end

  def finding(slug, title, body)
    { "slug" => slug, "status" => "open", "title" => title, "body" => body }
  end

  # [unit] --json carries the BODY. The human line shows only the title, which is
  # why a title-only match was never an option for the retro's duplicate guard.
  def test_json_list_carries_the_body_the_human_line_drops
    rows = [finding("finding-1", "fix flake", "Retro follow-up from rel-a: fix flake")]
    _reqs, out, err, status = run_triage("list", "--json", pages: [rows])

    assert status.success?, err
    parsed = JSON.parse(out)
    assert_equal 1, parsed.size
    assert_equal "Retro follow-up from rel-a: fix flake", parsed.first["body"],
                 "--json must expose the body — the duplicate guard matches on it"
  end

  # [unit] the human mode is unchanged — --json is additive, not a replacement.
  def test_text_list_still_prints_slug_status_and_title
    rows = [finding("finding-1", "fix flake", "b")]
    _reqs, out, err, status = run_triage("list", pages: [rows])

    assert status.success?, err
    assert_includes out, "finding-1"
    assert_includes out, "[open]"
    assert_includes out, "fix flake"
    assert_includes out, "(1 finding(s))"
    refute_includes out, "\"body\"", "the human mode stays human"
  end

  # [unit] THE TRUNCATION TRAP: more findings than one page. The CLI must walk
  # every page — a first-page-only read returns 100 of 150 with no error, and the
  # retro would then refile everything older than the window.
  def test_list_walks_every_page_instead_of_stopping_at_the_first
    page1 = (1..100).map { |i| finding("finding-a#{i}", "t#{i}", "b#{i}") }
    page2 = (1..50).map { |i| finding("finding-b#{i}", "u#{i}", "c#{i}") }
    reqs, out, err, status = run_triage("list", "--json", pages: [page1, page2])

    assert status.success?, err
    parsed = JSON.parse(out)
    assert_equal 150, parsed.size, "every page must be walked, not just the first"
    assert_includes parsed.map { |f| f["slug"] }, "finding-b50", "…including the last row of the last page"

    listed = reqs.map { |r| r[:path] }.select { |p| p.include?("triage_findings") }
    assert_equal 2, listed.size, "exactly one request per page"
    assert(listed.any? { |p| p.include?("page=2") }, "the second page must actually be requested: #{listed}")
  end

  # [unit] a single short page stops after one request — the loop must not spin
  # past the end (total_pages is the terminator, and an empty batch backs it up).
  def test_a_single_page_costs_a_single_request
    reqs, _out, err, status = run_triage("list", "--json", pages: [[finding("finding-1", "t", "b")]])

    assert status.success?, err
    listed = reqs.map { |r| r[:path] }.select { |p| p.include?("triage_findings") }
    assert_equal 1, listed.size, "one page, one request"
  end

  # [unit] the status filter still rides into the query — the retro asks for OPEN
  # findings specifically, since a dismissed one must not suppress a fresh filing.
  def test_the_status_filter_rides_into_the_query
    reqs, _out, err, status = run_triage("list", "--status", "dismissed", "--json", pages: [[]])

    assert status.success?, err
    listed = reqs.map { |r| r[:path] }.find { |p| p.include?("triage_findings") }
    assert_includes listed, "status=dismissed"
  end

  # [unit] an unknown flag is still refused rather than silently ignored — adding
  # --json must not turn the arg check into a rubber stamp.
  def test_an_unknown_flag_is_still_refused
    _reqs, _out, err, status = run_triage("list", "--nope", pages: [[]])

    refute status.success?, "an unknown argument must not pass silently"
    assert_includes err, "unknown argument"
  end
end
