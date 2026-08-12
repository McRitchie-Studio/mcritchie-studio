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

  def finding(slug, title, body, prior_art: "unknown", prior_art_note: nil)
    { "slug" => slug, "status" => "open", "title" => title, "body" => body,
      "prior_art" => prior_art, "prior_art_note" => prior_art_note }
  end

  # POST /api/v1/triage_findings echoes the params back as the created row, so a
  # `file` test can assert on BOTH the wire payload and the confirmation output.
  def run_file(*args)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve_echo(server, requests) }

    env = SessionEnv.neutralized(
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret"
    )
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, "file", *args)
    posted = requests.find { |r| r[:path] == "/api/v1/triage_findings" }
    [(posted ? JSON.parse(posted[:body]) : nil), out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve_echo(server, requests)
    loop do
      client = server.accept
      line = client.gets
      (client.close; next) if line.nil?

      _method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { path: path, body: body }

      payload =
        if path == "/api/v1/auth"
          JSON.generate("token" => "stub-token")
        else
          JSON.generate("data" => JSON.parse(body).merge("slug" => "finding-stub01"))
        end
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
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
    assert_includes err, "REFUSED"
    assert_includes err, "--nope"
  end

  # ---------------------------------------------------------------------------
  # PRIOR ART — three states, one flag.
  # ---------------------------------------------------------------------------

  # [unit] THE CENTRAL ASSERTION. Filing without a word about prior art must put
  # the string "unknown" ON THE WIRE. Omitting the key and letting the server
  # default it would work today and rot the day another client posts directly —
  # "nobody looked" is an answer the CLI states, not one it leaves to inference.
  def test_filing_without_prior_art_sends_unknown_explicitly
    posted, _out, err, status = run_file("--title", "Preview iframe has no sandbox")

    assert status.success?, err
    assert_equal "unknown", posted["prior_art"]
    refute posted.key?("prior_art_note"), "no note when nobody looked"
  end

  # [unit] …and it SAYS SO, out loud, on stderr. The whole failure being
  # prevented is a blank read as "none found", so the uninvestigated state is
  # the one state that must never file quietly.
  def test_an_uninvestigated_filing_announces_itself
    _posted, out, err, status = run_file("--title", "Preview iframe has no sandbox")

    assert status.success?, err
    assert_includes out, "filed finding-stub01"
    assert_includes err, "NOT INVESTIGATED"
    assert_includes err, "not as \"none\""
    assert_includes err, "--prior-art"
  end

  # [unit] the nudge is ONE line. `bin/release retro` files follow-ups in bulk
  # through this same path; a paragraph per finding is how a warning becomes
  # scenery, and scenery is what the blank field already was.
  def test_the_uninvestigated_nudge_stays_one_line
    _posted, _out, err, _status = run_file("--title", "Preview iframe has no sandbox")

    assert_equal 1, err.lines.count { |l| l.include?("prior art") },
                 "one line per filing — bulk retro runs go through here too"
  end

  # [unit] the cheap path: one word records "I looked, nothing was there".
  def test_prior_art_none_records_the_checked_state_with_no_note
    posted, out, err, status = run_file("--title", "New surface", "--prior-art", "none")

    assert status.success?, err
    assert_equal "none", posted["prior_art"]
    refute posted.key?("prior_art_note")
    assert_includes out, "prior art: none"
    refute_includes err, "NOT INVESTIGATED"
  end

  # [unit] anything that is not a reserved word is the EVIDENCE itself, carried
  # verbatim — this is the sentence that would have stopped the false finding.
  def test_prior_art_free_text_becomes_the_found_state_plus_the_note
    note = "TM's deleted preview view had the identical iframe, same URL, since 2025-11"
    posted, out, err, status = run_file("--title", "Preview iframe has no sandbox", "--prior-art", note)

    assert status.success?, err
    assert_equal "found", posted["prior_art"]
    assert_equal note, posted["prior_art_note"]
    assert_includes out, "prior art: found"
    assert_includes out, note, "the confirmation echoes the RESOLVED state so a mistype is visible"
  end

  # [unit] the list marks findings that DID the check. Legacy rows stay quiet:
  # ~90 rows all reading "unknown" is noise that gets tuned out in a day, and a
  # signal everyone ignores is worse than no signal.
  def test_the_list_marks_investigated_findings_and_leaves_the_rest_alone
    rows = [finding("finding-1", "checked one", "b", prior_art: "none"),
            finding("finding-2", "unchecked one", "b")]
    _reqs, out, err, status = run_triage("list", pages: [rows])

    assert status.success?, err
    assert_includes out, "finding-1  [open]  [prior art: none]  checked one"
    assert_includes out, "finding-2  [open]  unchecked one"
  end

  # ---------------------------------------------------------------------------
  # ARG PARSING — a tool must not report success it did not achieve.
  # ---------------------------------------------------------------------------

  # [unit] `--detail` was typed seven times on 2026-08-11 and seven findings were
  # reported as filed; none existed. The CLI DID exit 1 — but the message read
  # "unknown argument(s): --detail <your whole body text>", which looks like an
  # echo, not a refusal. The refusal must lead with the consequence, name the
  # FLAG, and point at the right one. And NOTHING may reach the board.
  def test_the_detail_typo_refuses_loudly_names_the_flag_and_suggests_body
    posted, out, err, status = run_file("--title", "A real finding",
                                        "--detail", "the body text I meant to file")

    refute status.success?, "a misspelled flag must not exit 0"
    assert_nil posted, "nothing may be filed when the arguments were refused"
    assert_includes err, "REFUSED — nothing was filed"
    assert_includes err, "unrecognized flag --detail"
    assert_includes err, "did you mean --body?"
    assert_includes err, "file accepts: --title --body --prior-art --source --repo"
    refute_includes out, "filed", "stdout must not claim a filing"
  end

  # [unit] the refusal names the FLAG, not the value tail. Printing the body back
  # is what made the old message read as an echo of the text just typed.
  def test_the_refusal_does_not_parrot_the_value_back
    _posted, _out, err, _status = run_file("--title", "A real finding",
                                           "--detail", "SENTINEL BODY TEXT")

    refute_includes err, "SENTINEL BODY TEXT",
                     "echoing the value is what made the refusal read as success"
  end

  # [unit] a flag-shaped value is a MISSING value. `--title --body "x"` must not
  # file a finding literally titled "--body".
  def test_a_flag_shaped_value_is_treated_as_a_missing_value
    posted, _out, err, status = run_file("--title", "--body", "the real body")

    refute status.success?
    assert_nil posted
    assert_includes err, "--title needs a value"
    assert_includes err, "nothing was filed"
  end

  # [unit] the underscore spelling of the new flag reaches its suggestion too — a
  # near-miss map only helps if the flag pattern actually matches the near miss.
  def test_the_underscore_spelling_of_prior_art_gets_its_suggestion
    posted, _out, err, status = run_file("--title", "A finding", "--prior_art", "none")

    refute status.success?
    assert_nil posted
    assert_includes err, "unrecognized flag --prior_art — did you mean --prior-art?"
  end

  # [unit] a trailing flag with no value at all is refused the same way.
  def test_a_trailing_flag_with_no_value_is_refused
    posted, _out, err, status = run_file("--title", "A real finding", "--body")

    refute status.success?
    assert_nil posted
    assert_includes err, "--body needs a value"
  end
end
