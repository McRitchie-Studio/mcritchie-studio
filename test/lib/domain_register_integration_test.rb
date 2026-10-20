# frozen_string_literal: true

# [integration] bin/domain-register end to end, as a real process: argument
# guard -> 1Password read (a fake `op` on PATH) -> the real Net::HTTP transport
# -> a stub Registrar API on 127.0.0.1. Proves that `check` and
# `register --dry-run` make ONLY domain-check calls (nothing is bought, no
# ledger line is written), that the token read from 1Password is the one sent,
# and that no secret reaches stdout or stderr.
#
#   ruby -Itest test/lib/domain_register_integration_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

class DomainRegisterIntegrationTest < Minitest::Test
  BIN = File.expand_path("../../bin/domain-register", __dir__)
  TOKEN = "cf-registrar-secret-int-0123456789"
  ACCOUNT = "acctint0123456789abcd"
  OK = "Alex in chat: buy acmecorp.dev at 10.46, 2026-10-19"

  QUOTES = {
    "acmecorp.dev" => { "name" => "acmecorp.dev", "registrable" => true, "tier" => "standard",
                        "pricing" => { "currency" => "USD", "registration_cost" => "10.46", "renewal_cost" => "10.46" } },
    "acme.ly" => { "name" => "acme.ly", "registrable" => false, "reason" => "extension_not_supported_via_api" },
    "gold.dev" => { "name" => "gold.dev", "registrable" => true, "tier" => "premium",
                    "pricing" => { "currency" => "USD", "registration_cost" => "2500.00", "renewal_cost" => "2500.00" } }
  }.freeze

  def setup
    @dir = Dir.mktmpdir("domain-register-int")
    @ledger = File.join(@dir, "ledger.jsonl")
    fake_bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(fake_bin)
    # A fake 1Password CLI: `op read <ref>` prints a value chosen by the ref.
    File.write(File.join(fake_bin, "op"), <<~SH)
      #!/bin/sh
      case "$2" in
        *cloudflare.registrar/api-token) printf '%s' '#{TOKEN}' ;;
        *cloudflare.studio.provision/account-id) printf '%s' '#{ACCOUNT}' ;;
        *) exit 1 ;;
      esac
    SH
    File.chmod(0o755, File.join(fake_bin, "op"))
    @path = "#{fake_bin}:#{ENV.fetch('PATH')}"
  end

  def teardown = FileUtils.remove_entry(@dir)

  def run_cli(*args, base: nil, status: :not_found, drop_purchase: false)
    @status = status
    @drop_purchase = drop_purchase
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests) }
    env = { "PATH" => @path, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_fake_admin", "MCR_OP_VAULT_ADMIN" => nil,
            "DOMAIN_REGISTER_LEDGER" => @ledger,
            "DOMAIN_REGISTER_API_BASE" => base || "http://127.0.0.1:#{server.addr[1]}/client/v4" }
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests)
    loop do
      client = server.accept
      method, path = (client.gets or break).split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : nil
      requests << { method: method, path: path, bearer: headers["authorization"], body: body && JSON.parse(body) }
      if @drop_purchase && method == "POST" && path.end_with?("/registrar/registrations")
        client.close # the request arrived; no answer goes back (the ambiguous case)
        next
      end
      status, payload = answer(method, path, body)
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed
  end

  def answer(method, path, body)
    if method == "POST" && path == "/client/v4/accounts/#{ACCOUNT}/registrar/domain-check"
      rows = JSON.parse(body)["domains"].filter_map { |d| QUOTES[d] }
      ["200 OK", JSON.generate({ "success" => true, "errors" => [], "result" => { "domains" => rows } })]
    elsif method == "GET" && path.end_with?("/registration-status")
      if @status == :not_found
        domain = path.split("/")[-2]
        ["404 Not Found", JSON.generate({ "success" => false, "result" => nil, "messages" => [],
                                          "errors" => [{ "code" => 10_000, "message" => "No workflow found for #{domain}" }] })]
      else
        ["200 OK", JSON.generate({ "success" => true, "errors" => [], "result" => { "state" => @status.to_s, "completed" => false } })]
      end
    else
      # Anything else (above all a registration POST) is a test failure, asserted below.
      ["500 Internal Server Error", JSON.generate({ "success" => false, "errors" => [{ "code" => 9999, "message" => "unexpected" }] })]
    end
  end

  def assert_only_domain_checks(requests)
    refute_empty requests
    requests.each do |r|
      assert_equal "POST", r[:method]
      assert_equal "/client/v4/accounts/#{ACCOUNT}/registrar/domain-check", r[:path]
    end
    refute File.exist?(@ledger), "a dry run or a check wrote the purchase ledger"
  end

  def refute_secrets(*texts)
    texts.each do |t|
      refute_includes t, TOKEN
      refute_includes t, ACCOUNT
    end
  end

  def test_check_reports_availability_price_and_reasons_and_buys_nothing
    requests, out, err, status = run_cli("check", "acmecorp.dev", "acme.ly", "gold.dev")

    assert status.success?, err
    assert_match "acmecorp.dev  AVAILABLE  USD 10.46 to register (1 year), USD 10.46 a year to renew", out
    assert_match "acme.ly  NOT AVAILABLE  (extension_not_supported_via_api", out
    assert_match "gold.dev  PREMIUM  USD 2500.00", out
    assert_only_domain_checks(requests)
    assert_equal [%w[acmecorp.dev acme.ly gold.dev]], requests.map { |r| r[:body]["domains"] }
    assert_equal ["Bearer #{TOKEN}"], requests.map { |r| r[:bearer] }.uniq, "the 1Password token is the one sent"
    refute_secrets(out, err)
  end

  def test_a_passing_dry_run_prints_the_plan_and_spends_nothing
    requests, out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--ok", OK, "--dry-run")

    assert status.success?, err
    assert_match "register --dry-run (spends nothing)", out
    assert_match "PLAN (all gates pass)", out
    assert_match %(POST /accounts/<account>/registrar/registrations {"domain_name":"acmecorp.dev","auto_renew":true,"privacy_mode":"redaction","years":1}), out
    assert_match "Nothing was bought", out
    assert_only_domain_checks(requests)
    assert_equal 1, requests.length
    refute_secrets(out, err)
  end

  def test_a_refusing_dry_run_lists_every_gate_and_exits_non_zero
    requests, out, = run_cli("register", "acmecorp.dev", "--price", "9.99", "--dry-run")
    assert_match "WOULD REFUSE", out
    assert_match "price changed: Cloudflare quotes USD 10.46 now", out
    assert_match "no --ok", out
    assert_only_domain_checks(requests)

    requests, out, = run_cli("register", "gold.dev", "--price", "2500.00", "--ok", OK, "--dry-run")
    assert_match "pass --premium", out
    assert_only_domain_checks(requests)
  end

  def test_a_refused_real_register_makes_no_registration_call
    requests, out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.45", "--ok", OK)

    assert_equal 2, status.exitstatus
    assert_match "REFUSED, nothing was bought", err
    assert_match "price changed", err
    assert_only_domain_checks(requests)
    refute_secrets(out, err)
  end

  def purchases(requests) = requests.select { |r| r[:method] == "POST" && r[:path].end_with?("/registrar/registrations") }

  def test_an_in_flight_workflow_at_cloudflare_refuses_a_purchase_with_no_post
    requests, out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--ok", OK, status: :in_progress)

    assert_equal 2, status.exitstatus
    assert_match "already exists at Cloudflare (state in_progress)", err
    assert_empty purchases(requests)
    refute File.exist?(@ledger)
    refute_secrets(out, err)
  end

  def test_a_purchase_with_no_answer_is_unknown_and_the_rerun_sends_no_second_post
    requests, out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--ok", OK, drop_purchase: true)

    assert_equal 2, status.exitstatus
    assert_match "Money MAY have moved", err
    assert_match "do NOT re-run register", err
    assert_equal 1, purchases(requests).length
    assert_equal %w[authorized unknown], File.readlines(@ledger).map { |l| JSON.parse(l)["event"] }
    refute_secrets(out, err, File.read(@ledger))

    requests, _out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--ok", OK)
    assert_equal 2, status.exitstatus
    assert_match "open authorization for acmecorp.dev", err
    assert_empty purchases(requests), "the re-run sent a second purchase"
  end

  def test_help_and_an_unknown_flag_run_nothing
    requests, out, _err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--ok", OK, "--help")
    assert status.success?
    assert_match "usage: bin/domain-register", out
    assert_empty requests

    requests, _out, err, status = run_cli("register", "acmecorp.dev", "--price", "10.46", "--yes")
    assert_equal 2, status.exitstatus
    assert_match "NOTHING ran", err
    assert_empty requests
  end

  def test_a_non_loopback_api_base_refuses_before_any_call
    _requests, out, err, status = run_cli("check", "acmecorp.dev", base: "https://evil.example/client/v4")
    assert_equal 2, status.exitstatus
    assert_match "may point only at loopback", err
    refute_secrets(out, err)
  end
end
