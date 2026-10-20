# frozen_string_literal: true

# [unit] bin/lib/domain_register: reading domain-check rows (price, premium,
# unsupported reasons), every refusal register makes before it spends money,
# the registration-status poll, the prerequisite hints, and that no secret is
# ever printed. Every HTTP call is faked (DomainRegisterFakeApi).
#
#   ruby -Itest test/lib/domain_register_test.rb

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "domain_register_fake_api"

class DomainRegisterTest < Minitest::Test
  F = DomainRegisterFakeApi
  R = DomainRegister::Runner
  OK = "Alex in chat: buy acmecorp.dev at 10.46, 2026-10-19"

  def setup
    @dir = Dir.mktmpdir("domain-register")
    @api = F.new.quote("acmecorp.dev")
    @out = StringIO.new
    @now = Time.utc(2026, 10, 19, 20, 0, 0)
  end

  def teardown = FileUtils.remove_entry(@dir)

  def ledger = DomainRegister::Ledger.new(File.join(@dir, "ledger.jsonl"))

  def runner(**opts)
    R.new(registrar: DomainRegister::Registrar.new(@api, token: F::TOKEN, account_id: F::ACCOUNT),
          ledger: ledger, out: @out, sleeper: ->(s) { @now += s }, clock: -> { @now }, actor: "steffon",
          zone_client: -> { DomainCutover::Cloudflare.new(@api, token: F::DNS_TOKEN, account_id: F::ACCOUNT) },
          **opts)
  end

  def quote(row) = DomainRegister::Quote.from_api(row)

  # ── parsing domain-check rows ────────────────────────────────────────────
  def test_a_standard_row_reads_exact_prices_and_is_available
    q = quote({ "name" => "AcmeCorp.dev", "registrable" => true, "tier" => "standard",
                "pricing" => { "currency" => "USD", "registration_cost" => "10.1", "renewal_cost" => "12.00" } })
    assert_equal "acmecorp.dev", q.name
    assert q.available?
    refute q.premium?
    assert_equal BigDecimal("10.10"), q.registration
    assert_equal "10.10", DomainRegister::Quote.format(q.registration)
    assert_match "USD 10.10 to register (1 year), USD 12.00 a year to renew", q.to_s
    assert_match "AVAILABLE", q.to_s
  end

  def test_a_premium_tier_row_is_premium_and_not_available
    q = quote({ "name" => "gold.dev", "registrable" => true, "tier" => "premium",
                "pricing" => { "currency" => "USD", "registration_cost" => "2500.00", "renewal_cost" => "2500.00" } })
    assert q.premium?
    refute q.available?
    assert_match "PREMIUM", q.to_s
  end

  def test_a_domain_premium_reason_is_premium_too
    q = quote({ "name" => "gold.com", "registrable" => false, "reason" => "domain_premium" })
    assert q.premium?
    assert_match "premium domain", q.reason_text
  end

  def test_every_documented_unsupported_reason_has_plain_words
    %w[domain_unavailable extension_not_supported_via_api extension_not_supported
       extension_disallows_registration domain_premium].each do |reason|
      q = quote({ "name" => "x.ly", "registrable" => false, "reason" => reason })
      refute q.available?, reason
      refute_equal reason, q.reason_text, "#{reason} has no plain-words explanation"
    end
    q = quote({ "name" => "x.ly", "registrable" => false, "reason" => "extension_not_supported_via_api" })
    assert_match "NOT AVAILABLE", q.to_s
    assert_match "dashboard", q.to_s
  end

  def test_an_unknown_reason_is_shown_verbatim
    assert_equal "brand_new_reason", quote({ "name" => "x.ly", "registrable" => false, "reason" => "brand_new_reason" }).reason_text
  end

  def test_check_prints_every_row_and_names_a_domain_cloudflare_skipped
    @api.quote("acme.ly", registrable: false, reason: "extension_not_supported_via_api", tier: nil, price: nil)
    quotes = runner.check(%w[acmecorp.dev acme.ly ghost.dev])
    assert_equal %w[acmecorp.dev acme.ly], quotes.map(&:name)
    assert_match "acmecorp.dev  AVAILABLE", @out.string
    assert_match "acme.ly  NOT AVAILABLE", @out.string
    assert_match "ghost.dev  NO ANSWER", @out.string
    assert_empty @api.registrations
  end

  def test_check_refuses_more_than_twenty_domains_before_any_call
    assert_raises(ArgumentError) { runner.check((1..21).map { |i| "d#{i}.dev" }) }
    assert_empty @api.log
  end

  # ── refusals ─────────────────────────────────────────────────────────────
  def standard = quote(@api.quotes["acmecorp.dev"])

  def test_all_gates_pass_with_the_exact_price_and_a_dated_ok
    assert_empty R.refusals(standard, price: "10.46", ok: OK, premium: false)
    assert_empty R.refusals(standard, price: "10.460".sub(/0\z/, ""), ok: OK, premium: false)
  end

  def test_refuses_without_ok
    assert_match(/no --ok/, R.refusals(standard, price: "10.46", ok: nil, premium: false).join)
    assert_match(/no --ok/, R.refusals(standard, price: "10.46", ok: "  ", premium: false).join)
  end

  def test_refuses_an_ok_with_no_date
    assert_match(/carries no date/, R.refusals(standard, price: "10.46", ok: "yes buy it", premium: false).join)
  end

  def test_refuses_a_price_mismatch_even_by_one_cent
    reasons = R.refusals(standard, price: "10.45", ok: OK, premium: false)
    assert_match(/price changed: Cloudflare quotes USD 10.46 now, Alex approved USD 10.45/, reasons.join)
  end

  def test_refuses_a_missing_or_malformed_price
    assert_match(/no --price/, R.refusals(standard, price: nil, ok: OK, premium: false).join)
    %w[$10.46 10.461 ten 10,46].each do |bad|
      assert_match(/is not a USD amount/, R.refusals(standard, price: bad, ok: OK, premium: false).join, bad)
    end
  end

  def test_refuses_an_unavailable_domain
    q = quote({ "name" => "taken.com", "registrable" => false, "reason" => "domain_unavailable" })
    assert_match(/taken.com is not available: domain_unavailable/, R.refusals(q, price: "10.46", ok: OK, premium: false).join)
  end

  def test_refuses_a_premium_domain_without_the_acknowledgement
    q = quote({ "name" => "gold.dev", "registrable" => true, "tier" => "premium",
                "pricing" => { "currency" => "USD", "registration_cost" => "2500.00", "renewal_cost" => "2500.00" } })
    assert_match(/pass --premium/, R.refusals(q, price: "2500.00", ok: OK, premium: false).join)
  end

  def test_an_acknowledged_premium_still_stops_while_the_api_cannot_register_premium
    refute R::PREMIUM_VIA_API, "flip this only once Cloudflare's API registers premium domains"
    q = quote({ "name" => "gold.dev", "registrable" => true, "tier" => "premium",
                "pricing" => { "currency" => "USD", "registration_cost" => "2500.00", "renewal_cost" => "2500.00" } })
    reasons = R.refusals(q, price: "2500.00", ok: OK, premium: true)
    assert_match(/does not register premium domains yet/, reasons.join)
    refute_match(/pass --premium/, reasons.join)
  end

  def test_refuses_a_non_usd_quote
    q = quote({ "name" => "acme.dev", "registrable" => true, "tier" => "standard",
                "pricing" => { "currency" => "EUR", "registration_cost" => "10.46", "renewal_cost" => "10.46" } })
    assert_match(/quoted EUR, not USD/, R.refusals(q, price: "10.46", ok: OK, premium: false).join)
  end

  def test_refuses_when_cloudflare_returned_no_row
    assert_match(/no domain-check row/, R.refusals(nil, price: "10.46", ok: OK, premium: false).join)
  end

  def test_register_refusal_makes_no_registration_call_and_writes_no_ledger
    [{ price: "10.46", ok: nil }, { price: "9.99", ok: OK }].each do |args|
      err = assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", **args) }
      assert_match "REFUSED, nothing was bought", err.message
    end
    @api.quote("acmecorp.dev", registrable: false, reason: "domain_unavailable", tier: nil, price: nil)
    assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "10.46", ok: OK) }
    @api.quote("acmecorp.dev", tier: "premium", price: "2500.00")
    assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "2500.00", ok: OK) }

    assert_empty @api.registrations
    assert_empty ledger.entries
  end

  def test_register_rechecks_immediately_before_the_post
    runner.register("acmecorp.dev", price: "10.46", ok: OK)
    verbs = @api.log.map { |c| URI(c[:url]).path.split("/").last(2).join("/") }
    assert_equal "registrar/domain-check", verbs.first
    assert_equal "registrar/registrations", verbs[1]
  end

  # ── a real (faked) purchase ──────────────────────────────────────────────
  def test_register_sends_auto_renew_and_redaction_and_records_the_ok_before_the_post
    @api.zones << { "id" => "zone1", "name" => "acmecorp.dev", "status" => "active",
                    "name_servers" => %w[ada.ns.cloudflare.com bob.ns.cloudflare.com] }
    at_post = nil
    @api.on_register = -> { at_post = ledger.entries.map { |e| e["event"] } }
    assert runner.register("acmecorp.dev", price: "10.46", ok: OK)

    assert_equal %w[authorized], at_post, "the OK must be on the ledger BEFORE the money moves"
    assert_equal 1, @api.registrations.length
    post = @api.registrations.first
    assert_equal({ "domain_name" => "acmecorp.dev", "auto_renew" => true, "privacy_mode" => "redaction", "years" => 1 },
                 post[:body])
    events = ledger.entries
    assert_equal %w[authorized registered], events.map { |e| e["event"] }
    assert_equal OK, events.first["ok"]
    assert_equal "10.46", events.first["price"]
    assert_equal "steffon", events.first["by"]
    assert_match "zone: acmecorp.dev is in our account (id zone1", @out.string
    assert_match "NEXT: Steffon's domain-dns SOP", @out.string
  end

  def test_a_failed_post_is_ledgered_and_names_the_dashboard_prerequisite
    { "No default payment method on file" => /Billing > Payment info/,
      "Domain Registration Agreement has not been accepted" => /accept the agreement/,
      "No registrant contact provided and no default address book entry found" => /default registrant contact/,
      "Authentication error" => /never the DNS token/ }.each do |message, hint|
      @api.register_error = [403, 10_000, message]
      err = assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "10.46", ok: OK) }
      assert_match hint, err.message, message
    end
    assert_equal %w[authorized failed] * 4, ledger.entries.map { |e| e["event"] }
  end

  # ── polling ──────────────────────────────────────────────────────────────
  def test_a_202_is_polled_through_blocked_to_succeeded
    @api.register_reply = { status: 202, result: @api.workflow("pending") }
    @api.statuses = [@api.workflow("in_progress"), @api.workflow("blocked"), @api.workflow("succeeded")]
    runner(zone_attempts: 1).register("acmecorp.dev", price: "10.46", ok: OK)
    assert_equal 3, @api.log.count { |c| c[:url].end_with?("/registration-status") }
    assert_equal "registered", ledger.entries.last["event"]
  end

  def test_polling_stops_at_action_required_and_surfaces_the_action
    @api.register_reply = { status: 202, result: @api.workflow("in_progress") }
    @api.statuses = [@api.workflow("action_required", action: "verify the registrant email")]
    err = assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "10.46", ok: OK) }
    assert_match "verify the registrant email", err.message
    assert_equal 1, @api.log.count { |c| c[:url].end_with?("/registration-status") }
    assert_equal "pending", ledger.entries.last["event"]
  end

  def test_a_failed_workflow_names_its_error
    @api.register_reply = { status: 202, result: @api.workflow("in_progress") }
    @api.statuses = [@api.workflow("failed", error: { "code" => "payment_declined", "message" => "card declined" })]
    err = assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "10.46", ok: OK) }
    assert_match "registration FAILED: payment_declined card declined", err.message
    assert_match "Payment info", err.message
    assert_equal "failed", ledger.entries.last["event"]
  end

  def test_polling_times_out_without_telling_anyone_to_re_register
    @api.register_reply = { status: 202, result: @api.workflow("in_progress") }
    @api.statuses = [@api.workflow("in_progress")]
    err = assert_raises(DomainRegister::Abort) do
      runner(poll_interval: 5, poll_timeout: 20).register("acmecorp.dev", price: "10.46", ok: OK)
    end
    assert_match "do NOT re-run register", err.message
    assert_equal 4, @api.log.count { |c| c[:url].end_with?("/registration-status") }
    assert_equal "pending", ledger.entries.last["event"]
    assert_equal 1, @api.registrations.length
  end

  def test_an_unknown_state_stops_polling
    err = assert_raises(DomainRegister::Abort) { runner.poll("acmecorp.dev", { "state" => "weird" }) }
    assert_match "unknown workflow state", err.message
  end

  def test_a_missing_zone_warns_but_the_purchase_stands
    assert_equal false, runner(zone_attempts: 2).register("acmecorp.dev", price: "10.46", ok: OK)
    assert_match "WARNING: no zone for acmecorp.dev", @out.string
    assert_equal "registered", ledger.entries.last["event"]
  end

  # ── secrets ──────────────────────────────────────────────────────────────
  def test_no_token_or_account_id_reaches_output_or_errors_or_the_ledger
    @api.zones << { "id" => "zone1", "name" => "acmecorp.dev", "status" => "active", "name_servers" => [] }
    runner.register("acmecorp.dev", price: "10.46", ok: OK, dry_run: true)
    runner.register("acmecorp.dev", price: "10.46", ok: OK)
    @api.register_error = [400, 10_000, "echo #{F::TOKEN} #{F::ACCOUNT}"]
    err = assert_raises(DomainRegister::Abort) { runner.register("acmecorp.dev", price: "10.46", ok: OK) }

    text = @out.string + err.message + File.read(ledger.path)
    [F::TOKEN, F::DNS_TOKEN, F::ACCOUNT].each { |secret| refute_includes text, secret }
    assert_includes err.message, "[REDACTED]"
  end

  # ── credentials ──────────────────────────────────────────────────────────
  def test_registrar_credentials_read_the_registrar_item_not_the_dns_token
    reads = []
    reader = lambda do |ref, _env|
      reads << ref
      ref.include?("cloudflare.registrar/api-token") ? "reg-token" : "acct"
    end
    with_env("OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_x") do
      assert_equal %w[reg-token acct], DomainRegister::Credentials.registrar(reader)
    end
    assert_equal %w[op://studio-agents-admin/cloudflare.registrar/api-token
                    op://studio-agents-admin/cloudflare.studio.provision/account-id], reads
  end

  def test_an_empty_registrar_item_says_what_alex_pastes
    with_env("OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_x") do
      err = assert_raises(DomainRegister::Abort) { DomainRegister::Credentials.registrar(->(_r, _e) { "" }) }
      assert_match "is empty: Alex pastes the Registrar token", err.message
    end
  end

  private

  def with_env(vars)
    vars = vars.merge("MCR_OP_VAULT_ADMIN" => nil)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
