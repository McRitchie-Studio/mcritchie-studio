# frozen_string_literal: true

# [integration] DomainCutover::Runner end to end: plan -> verify -> finalize ->
# workspace, against DomainCutoverFakeWorld (stubbed DoH, RDAP, Cloudflare and
# Heroku). Each test asserts what the WORLD looks like afterwards, not which
# method ran: the zone holds every record, the redirect rule is disabled then
# enabled, APP_HOST moves only after the certificate issued.
#
#   ruby -Itest test/lib/domain_cutover_integration_test.rb

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "domain_cutover_fake_world"

class DomainCutoverIntegrationTest < Minitest::Test
  DOMAIN = "example.com"
  APP = "example-app"
  T0 = Time.utc(2026, 10, 13, 17, 0, 0)
  W = DomainCutoverFakeWorld

  def setup
    @dir = Dir.mktmpdir("domain-cutover")
    @world = W.new(domain: DOMAIN, app: APP)
    @now = T0
    @out = StringIO.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def runner(dry_run: false)
    DomainCutover::Runner.new(
      app: APP, domain: DOMAIN, dry_run: dry_run, out: @out, clock: -> { @now },
      store: DomainCutover::StateStore.new(@dir),
      cloudflare: DomainCutover::Cloudflare.new(@world, token: W::TOKEN, account_id: "acct-1"),
      heroku: DomainCutover::Heroku.new(@world, key: W::HEROKU_KEY, sleeper: ->(_) { }),
      doh: DomainCutover::Doh.new(@world), rdap: DomainCutover::Rdap.new(@world)
    )
  end

  def state = JSON.parse(File.read(File.join(@dir, "#{DOMAIN}.json")))

  def zone_has?(name, type, content, proxied: nil)
    @world.zone_records.any? do |r|
      r["name"] == name && r["type"] == type && r["content"] == content && (proxied.nil? || r["proxied"] == proxied)
    end
  end

  # Plan, the registrar moves, the caches turn over: the world as verify sees it.
  def planned_and_delegated
    runner.plan
    @world.registry_on_cloudflare!
    @world.delegate_to_cloudflare!
  end

  def test_plan_builds_the_zone_from_an_empty_import_and_writes_the_redirect_disabled
    runner.plan

    z = @world.zone
    assert_equal "example.com", z["zone"]["name"]
    # Every snapshot record copied exactly and DNS only, subdomains included.
    assert zone_has?(DOMAIN, "MX", "smtp.google.com", proxied: false)
    assert zone_has?(DOMAIN, "TXT", "google-site-verification=abc", proxied: false)
    assert zone_has?(DOMAIN, "TXT", "v=spf1 include:_spf.google.com ~all", proxied: false)
    assert zone_has?("google._domainkey.#{DOMAIN}", "TXT", "v=DKIM1; k=rsa; p=MIIBIjAN")
    assert zone_has?("_dmarc.#{DOMAIN}", "TXT", "v=DMARC1; p=none; rua=mailto:team@#{DOMAIN}")
    assert zone_has?("in.#{DOMAIN}", "MX", "inbound-smtp.us-east-1.amazonaws.com", proxied: false),
           "the in. inbound MX a past move dropped must be copied"
    # The app records replace Squarespace's forwarding A records and www CNAME.
    assert zone_has?(DOMAIN, "CNAME", W::HEROKU_TARGET, proxied: false)
    assert zone_has?("www.#{DOMAIN}", "CNAME", DOMAIN, proxied: true)
    refute @world.zone_records.any? { |r| r["type"] == "A" }, "Squarespace's forwarding A records are not copied"
    refute zone_has?("www.#{DOMAIN}", "CNAME", "ext-sq.squarespace.com")

    assert_equal "strict", @world.ssl[z["zone"]["id"]]
    rule = @world.redirect_rule
    assert_equal false, rule["enabled"], "plan must write the www redirect DISABLED"
    assert_equal %((http.host eq "www.#{DOMAIN}")), rule["expression"]
    assert_equal %(concat("https://#{DOMAIN}", http.request.uri.path)),
                 rule.dig("action_parameters", "from_value", "target_url", "expression")
    assert_equal 301, rule.dig("action_parameters", "from_value", "status_code")
    assert_equal true, rule.dig("action_parameters", "from_value", "preserve_query_string")

    assert_equal "pending", @world.domains[DOMAIN]["acm_status"], "the bare domain is added to Heroku"
    assert_equal "www.#{DOMAIN}", @world.config["APP_HOST"], "plan never moves APP_HOST"

    s = state
    assert_equal "planned", s["phase"]
    assert_equal W::CF_NS, s["nameservers"]
    assert_nil s["ns_seen_at"]
    text = @out.string
    assert_includes text, "scheduled outage", "a published DS puts the outage step in the guide"
    assert_includes text, "account.squarespace.com/domains"
    W::CF_NS.each { |ns| assert_includes text, ns }
    refute_includes text, W::TOKEN
    refute_includes text, W::HEROKU_KEY
  end

  def test_plan_keeps_other_rules_in_the_redirect_phase
    runner.plan
    id = @world.zone["zone"]["id"]
    @world.rules[id].unshift({ "id" => "r-other", "ref" => "old_brand", "expression" => "(http.host eq \"old.example\")",
                               "action" => "redirect", "enabled" => true })
    runner.plan
    refs = @world.rules[id].map { |r| r["ref"] }
    assert_equal ["old_brand", DomainCutover::Cloudflare::REDIRECT_REF], refs
  end

  def test_plan_refuses_during_a_servfail_outage_and_writes_nothing
    @world.servfail = true
    err = assert_raises(DomainCutover::Abort) { runner.plan }
    assert_match(/SERVFAIL/, err.message)
    assert_empty @world.writes
  end

  def test_plan_refuses_a_zone_in_another_cloudflare_account
    @world.registrar = "Cloudflare, Inc."
    @world.registry_ns = W::CF_NS
    err = assert_raises(DomainCutover::Abort) { runner.plan }
    assert_match(/anywhere except Cloudflare Registrar/, err.message)
    assert_empty @world.writes
  end

  def test_plan_refuses_an_unknown_audience_before_any_call
    assert_raises(DomainCutover::Abort) { runner.plan(to: "bob") }
    assert_empty @world.log
  end

  def test_dry_run_prints_every_write_and_makes_none
    runner(dry_run: true).plan

    assert_empty @world.writes, "a dry run sends only GETs"
    refute File.exist?(File.join(@dir, "#{DOMAIN}.json")), "a dry run saves no state"
    text = @out.string
    assert_includes text, "WOULD HEROKU POST /apps/#{APP}/domains"
    assert_includes text, "WOULD CLOUDFLARE POST /zones"
    assert_includes text, "WOULD CLOUDFLARE PATCH /zones/<zone-id>/settings/ssl"
    assert_includes text, %("enabled":false)
    assert_operator text.scan("WOULD CLOUDFLARE POST /zones/<zone-id>/dns_records").size, :>=, 7
  end

  def test_verify_is_not_green_before_the_registrar_moves
    runner.plan
    refute runner.verify
    assert_nil state["ns_seen_at"]
    assert_match(/DNSSEC off/, @out.string)
  end

  def test_verify_activates_the_zone_and_issues_acm_once_delegated
    planned_and_delegated
    assert runner.verify, @out.string

    assert_equal "active", @world.zone["zone"]["status"], "verify triggers the activation check"
    assert_equal "cert issued", @world.domains[DOMAIN]["acm_status"], "ACM is refreshed once the bare domain resolves"
    assert_equal T0.iso8601, state["ns_seen_at"]
    assert_equal "verified", state["phase"]
  end

  def test_verify_names_a_record_the_public_resolvers_lack
    planned_and_delegated
    @world.doh_override[["in.#{DOMAIN}", "MX"]] = []

    refute runner.verify
    assert_match(/\[WAIT\] public DNS answers the zone \(DoH\): in\.example\.com MX differs on google\+cloudflare/, @out.string)
  end

  def test_finalize_refuses_inside_six_hours_and_writes_nothing
    planned_and_delegated
    runner.verify
    before = @world.writes.size
    @now = T0 + (6 * 3600) - 60

    err = assert_raises(DomainCutover::Abort) { runner.finalize }
    assert_match(/REFUSED until #{Regexp.escape((T0 + 21_600).iso8601)}/, err.message)
    assert_equal before, @world.writes.size
    assert_equal false, @world.redirect_rule["enabled"]
    assert_equal "www.#{DOMAIN}", @world.config["APP_HOST"]
  end

  def test_a_registrar_revert_restarts_the_six_hour_clock
    planned_and_delegated
    runner.verify
    @world.registry_ns = %w[nsa1.squarespacedns.com nsa2.squarespacedns.com]
    @now = T0 + 21_600
    assert_match(/no longer shows Cloudflare's/, assert_raises(DomainCutover::Abort) { runner.finalize }.message)
    runner.verify
    @world.registry_on_cloudflare!
    @now = T0 + (8 * 3600)
    runner.verify
    @now = T0 + (12 * 3600)
    assert_match(/REFUSED until #{Regexp.escape((T0 + (14 * 3600)).iso8601)}/,
                 assert_raises(DomainCutover::Abort) { runner.finalize }.message)
  end

  def test_finalize_refuses_until_the_certificate_issues
    planned_and_delegated
    runner.verify
    @world.domains[DOMAIN]["acm_status"] = "pending"
    @now = T0 + 21_600 + 60
    before = @world.writes.size

    err = assert_raises(DomainCutover::Abort) { runner.finalize }
    assert_match(/APP_HOST moves only after the certificate issues/, err.message)
    assert_equal before, @world.writes.size
    assert_equal "www.#{DOMAIN}", @world.config["APP_HOST"]
  end

  def test_finalize_after_six_hours_moves_app_host_and_enables_the_redirect
    planned_and_delegated
    runner.verify
    @world.config["APP_HOSTS"] = "www.#{DOMAIN}"
    @now = T0 + 21_600

    assert runner.finalize, @out.string
    assert_equal DOMAIN, @world.config["APP_HOST"], "read back through the lagging config-vars read"
    assert_equal "www.#{DOMAIN},#{DOMAIN}", @world.config["APP_HOSTS"], "the allow-list gains the bare domain"
    assert_equal true, @world.redirect_rule["enabled"]
    assert_equal "finalized", state["phase"]
    assert_match(/APP_HOST, APP_HOSTS settled/, @out.string)
  end

  def test_status_names_the_next_action_and_when
    planned_and_delegated
    runner.verify
    @out.truncate(0)
    @out.rewind
    @now = T0 + 3600

    runner.status
    assert_match(/registry NS:   Cloudflare's since #{Regexp.escape(T0.iso8601)}/, @out.string)
    assert_match(/finalize allowed at #{Regexp.escape((T0 + 21_600).iso8601)}/, @out.string)
  end

  def test_workspace_writes_google_mail_and_merges_spf
    planned_and_delegated
    id = @world.zone["zone"]["id"]
    spf = @world.zone_records.find { |r| r["content"].start_with?("v=spf1") }
    spf["content"] = "v=spf1 include:amazonses.com ~all"
    mx = @world.zone_records.find { |r| r["type"] == "MX" && r["name"] == DOMAIN }
    @world.zones[id]["records"].delete(mx)

    runner.workspace(verification: "google-site-verification=xyz", dkim: "v=DKIM1; k=rsa; p=MIIBIjAN")

    assert zone_has?(DOMAIN, "TXT", "google-site-verification=xyz")
    DomainCutover::Workspace::GOOGLE_MX.each do |pri, host|
      assert(@world.zone_records.any? { |r| r["type"] == "MX" && r["priority"] == pri && r["content"] == host })
    end
    spfs = @world.zone_records.select { |r| r["name"] == DOMAIN && r["content"].start_with?("v=spf1") }
    assert_equal ["v=spf1 include:amazonses.com include:_spf.google.com ~all"], spfs.map { |r| r["content"] }
    assert_match(/workspace REFUSED/, assert_raises(DomainCutover::Abort) {
      runner.workspace(rua: "mailto:other@#{DOMAIN}")
    }.message, "a different DMARC needs --replace-mail")
  end

  def test_workspace_refuses_a_foreign_mx_without_replace_mail
    planned_and_delegated
    @world.zone_records.find { |r| r["type"] == "MX" && r["name"] == DOMAIN }["content"] = "mx.fastmail.com"
    before = @world.writes.size

    err = assert_raises(DomainCutover::Abort) { runner.workspace(verification: "abc") }
    assert_match(/MX: .*mx\.fastmail\.com/, err.message)
    assert_equal before, @world.writes.size

    runner.workspace(verification: "abc", replace_mail: true)
    refute(@world.zone_records.any? { |r| r["content"] == "mx.fastmail.com" })
  end
end
