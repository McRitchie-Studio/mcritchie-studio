# frozen_string_literal: true

# Integration coverage for bin/verify-review-hop — the CLI driven end to end
# against a REAL HTTP server over a REAL socket, through all five legs.
#
# Run directly: `ruby -Itest test/commands/verify_review_hop_test.rb`.
# Also picked up by the normal `bin/rails test` sweep.
#
# A stub, not the Rails app, because what is under test is the CLI's chaining:
# that it starts at the CTA, that it carries the session cookie forward, that it
# POSTs the consume without forcing the method across the redirect, and above
# all that a broken leg STOPS the run instead of degrading into the next one.
# The chain against the real stack is exercised by hand and recorded on the
# task; this locks in the wiring so it cannot rot silently.

require "minitest/autorun"
require "cgi"
require "json"
require "open3"
require "rbconfig"
require "socket"
require_relative "../support/session_env"

class VerifyReviewHopTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "verify-review-hop")
  SLUG = "some-task"
  REVIEW_PATH = "/admin/style"

  # A loopback HTTP server that answers the five legs. `scenario` bends exactly
  # one leg so each failure can be asserted in isolation.
  class HopServer
    attr_reader :port

    def initialize(scenario: :healthy)
      @scenario = scenario
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
      @thread.abort_on_exception = false
    end

    def base = "http://127.0.0.1:#{port}"

    def close
      @server.close
      @thread.kill
    end

    private

    def serve
      loop do
        socket = @server.accept
        handle(socket)
      rescue IOError, Errno::EBADF
        break
      rescue StandardError
        next
      end
    end

    def handle(socket)
      line = socket.gets.to_s
      method, target, = line.split(" ")
      headers = {}
      while (h = socket.gets) && h.strip != ""
        k, v = h.split(":", 2)
        headers[k.to_s.downcase] = v.to_s.strip
      end
      socket.read(headers["content-length"].to_i) if headers["content-length"]

      socket.write(response_for(method, target.to_s))
    ensure
      socket.close
    end

    def response_for(method, target)
      path = target.split("?").first

      case
      when path == "/tasks/#{SLUG}/local_review"
        cta_response
      when path == "/_studio/local_review"
        mint_response(target)
      when path == "/l/tok-1" && method == "GET"
        ok(%(<form><input name="authenticity_token" value="csrf-1" /></form>), cookie: true)
      when path == "/l/tok-1" && method == "POST"
        redirect(@scenario == :not_admin ? "#{base}/" : "#{base}#{REVIEW_PATH}")
      when path == REVIEW_PATH
        ok("<h1>Design System</h1>")
      when path == "/"
        ok("<h1>Home</h1>")
      when path == "/login"
        ok("<h1>Sign in</h1>")
      else
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      end
    end

    def cta_response
      case @scenario
      when :dead_end then redirect("#{base}/tasks/#{SLUG}")
      when :cta_404 then "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      else redirect("#{base}/_studio/local_review?return_to=#{CGI.escape(REVIEW_PATH)}")
      end
    end

    def mint_response(target)
      has_email = target.include?("email=")

      # studio-engine < 0.36.0: no reviewer fallback, so an address is REQUIRED.
      if @scenario == :sub_floor
        return has_email ? redirect("#{base}/l/tok-1") : redirect("#{base}/login")
      end

      # At/above the floor the live CTA sends NO email. If one ever appears here
      # the recipe has regressed to verifying a path the button does not take.
      return "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" if has_email

      @scenario == :no_reviewer ? redirect("#{base}/login") : redirect("#{base}/l/tok-1")
    end

    def redirect(location)
      "HTTP/1.1 302 Found\r\nLocation: #{location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    end

    def ok(body, cookie: false)
      set = cookie ? "Set-Cookie: _session=abc; path=/\r\n" : ""
      "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n#{set}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end
  end

  def run_hop(scenario: :healthy, args: nil)
    server = HopServer.new(scenario: scenario)
    argv = args || [SLUG, "--board", server.base]
    out, _err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, SCRIPT, *argv, "--json")
    [JSON.parse(out), status]
  ensure
    server&.close
  end

  def leg(report, name) = report["legs"].find { |l| l["leg"] == name }

  # [integration] the whole hop, CTA through landing, over a real socket
  def test_healthy_hop_passes_every_leg
    report, status = run_hop

    assert status.success?, "expected exit 0, got #{status.exitstatus}: #{report}"
    assert report["ok"]
    assert_equal %w[cta mint confirm consume landing], report["legs"].map { |l| l["leg"] }
    assert(report["legs"].all? { |l| l["ok"] }, report.inspect)
  end

  # [integration] THE acceptance miss: a dead-ended CTA is a 302, and the run
  # must fail AT leg 1 rather than proceeding into the local legs that all pass
  def test_dead_end_cta_fails_at_leg_one_and_stops
    report, status = run_hop(scenario: :dead_end)

    refute status.success?
    refute report["ok"]
    assert_equal "cta_dead_end", leg(report, "cta")["code"]
    assert_nil leg(report, "mint"), "the run must STOP at the broken leg, not carry on"
  end

  # [integration] the hyphen spelling (/tasks/:slug/local-review) 404s
  def test_cta_404_is_a_failure
    report, status = run_hop(scenario: :cta_404)

    refute status.success?
    assert_equal "cta_not_redirect", leg(report, "cta")["code"]
  end

  # [integration] MISSING_EMAIL — the case the old recipe finished as `/signin 200`
  def test_unresolvable_reviewer_fails_at_the_mint
    report, status = run_hop(scenario: :no_reviewer)

    refute status.success?
    assert_equal "mint_no_reviewer", leg(report, "mint")["code"]
    assert_nil leg(report, "confirm"), "a failed mint must not degrade into scraping the sign-in page"
  end

  # [integration] the quiet failure: signed in, bounced to / by require_admin, 200
  def test_landing_on_root_fails_even_though_it_is_a_200
    report, status = run_hop(scenario: :not_admin)

    refute status.success?
    assert leg(report, "consume")["ok"], "the consume itself succeeds — that is why this is quiet"
    assert_equal "landing_not_authorized", leg(report, "landing")["code"]
  end

  # [integration] an app below the 0.36.0 floor (turf-monster is on 0.31.0) has no
  # reviewer fallback: the address-free mint the button uses cannot work there,
  # and the failure must name the floor rather than blaming the desk's seeds
  def test_sub_floor_app_fails_without_an_address_and_names_the_floor
    report, status = run_hop(scenario: :sub_floor)

    refute status.success?
    assert_equal "mint_no_reviewer", leg(report, "mint")["code"]
    assert_match(/0\.36\.0/, leg(report, "mint")["detail"])
    assert_match(/--email/, leg(report, "mint")["detail"])
  end

  # [integration] --email rescues the sub-floor app, and the run is STAMPED as a
  # deviation so it never reads as a clean check of the button's own path
  def test_sub_floor_app_passes_with_email_and_records_the_deviation
    server = HopServer.new(scenario: :sub_floor)
    out, _err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, SCRIPT,
                                       SLUG, "--board", server.base,
                                       "--email", "someone@example.com", "--json")
    report = JSON.parse(out)

    assert status.success?, out
    assert report["ok"]
    assert_equal "someone@example.com", report["email_override"]
  ensure
    server&.close
  end

  # [integration] --local-url skips the CTA leg and says so; a skipped leg must
  # never read as a pass
  def test_local_url_marks_the_cta_leg_skipped
    server = HopServer.new(scenario: :healthy)
    out, _err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, SCRIPT,
                                       "--local-url", "#{server.base}#{REVIEW_PATH}", "--json")
    report = JSON.parse(out)

    assert status.success?
    assert_equal "skipped", leg(report, "cta")["code"]
    assert_nil leg(report, "cta")["ok"]
    assert(%w[mint confirm consume landing].all? { |n| leg(report, n)["ok"] })
  ensure
    server&.close
  end

  # [integration] a non-loopback --local-url is refused before any request
  def test_local_url_must_be_loopback
    _out, err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, SCRIPT,
                                       "--local-url", "https://qa.mcritchie.studio/admin/style")

    refute status.success?
    assert_match(/not a loopback host/, err)
  end

  # [integration] no slug and no --local-url is a usage error
  def test_requires_a_slug_or_local_url
    _out, err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, SCRIPT)

    refute status.success?
    assert_match(/give a task slug/, err)
  end
end
