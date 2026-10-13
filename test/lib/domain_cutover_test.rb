# frozen_string_literal: true

# [unit] DomainCutover's pieces, each with HTTP stubbed: the DoH reader, the RDAP
# registrar and DNSSEC read, record normalising and diffing, guide selection and
# content, the Workspace mail plan, credentials, and the finalize 6h refusal.
#
#   ruby -Itest test/lib/domain_cutover_test.rb

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/domain_cutover"

class DomainCutoverTest < Minitest::Test
  DC = DomainCutover
  R = DC::Records

  # Answers one canned body per host, and records every call.
  class Stub
    attr_reader :calls

    def initialize(bodies)
      @bodies = bodies
      @calls = []
    end

    def call(verb, url, headers: {}, body: nil)
      @calls << { verb: verb, url: url, headers: headers }
      body = @bodies.fetch(URI(url).host)
      DC::Response.new(status: 200, body: JSON.generate(body.respond_to?(:call) ? body.call(url) : body))
    end
  end

  def rec(name, type, content, priority: nil, proxied: nil, id: nil)
    DC::Record.new(name: name, type: type, content: content, priority: priority, proxied: proxied, id: id)
  end

  # ── DoH ──────────────────────────────────────────────────────────────────
  def test_doh_reads_both_resolvers_over_https_and_never_dns
    stub = Stub.new(
      "dns.google" => { "Status" => 0, "Answer" => [
        { "name" => "www.example.com.", "type" => 5, "data" => "example.com." },
        { "name" => "example.com.", "type" => 16, "data" => "v=spf1 ~all" }
      ] },
      "cloudflare-dns.com" => { "Status" => 0, "Answer" => [
        { "name" => "example.com.", "type" => 16, "data" => "\"v=spf1 \" \"~all\"" }
      ] }
    )
    google, cloudflare = DC::Doh.new(stub).both("example.com", "TXT")

    assert_equal ["v=spf1 ~all"], google.records.map(&:content), "a CNAME-chain link is not the answer"
    assert_equal ["v=spf1 ~all"], cloudflare.records.map(&:content), "quoted 255-byte segments join"
    assert(stub.calls.all? { |c| c[:url].start_with?("https://") && c[:headers]["accept"] == "application/dns-json" })
  end

  def test_doh_reads_a_ds_with_checking_disabled_and_flags_servfail
    stub = Stub.new("dns.google" => ->(url) { url.include?("cd=1") ? { "Status" => 0, "Answer" => [{ "name" => "x.llc.", "type" => 43, "data" => "1 13 2 AB" }] } : { "Status" => 2 } },
                    "cloudflare-dns.com" => { "Status" => 2 })
    doh = DC::Doh.new(stub)

    assert doh.ds_published?("x.llc")
    assert doh.query("google", "x.llc", "A").servfail?
    assert_equal "SERVFAIL", doh.query("cloudflare", "x.llc", "A").label
  end

  # ── RDAP ─────────────────────────────────────────────────────────────────
  def rdap_body(registrar, signed:, ns: %w[NSA1.SQUARESPACEDNS.COM])
    { "entities" => [{ "roles" => ["registrar"], "vcardArray" => ["vcard", [["fn", {}, "text", registrar]]] }],
      "nameservers" => ns.map { |n| { "ldhName" => n } }, "secureDNS" => { "delegationSigned" => signed } }
  end

  def test_rdap_reads_registrar_nameservers_and_delegation_signed
    info = DC::Rdap.new(Stub.new("rdap.org" => rdap_body("Squarespace Domains II LLC", signed: true))).lookup("x.llc")

    assert_equal "squarespace", info.registrar_key
    assert_equal ["nsa1.squarespacedns.com"], info.nameservers
    assert_equal true, info.delegation_signed
    refute DC::Rdap.new(Stub.new("rdap.org" => rdap_body("x", signed: false))).lookup("x.llc").delegation_signed
  end

  def test_registrar_keys
    { "GoDaddy.com, LLC" => "godaddy", "NameCheap, Inc." => "namecheap", "Porkbun LLC" => "porkbun",
      "Cloudflare, Inc." => "cloudflare", "Google LLC" => "squarespace", "Gandi SAS" => "other", nil => "other" }
      .each { |name, key| assert_equal key, DC::Rdap.registrar_key(name), name.inspect }
  end

  # ── records ──────────────────────────────────────────────────────────────
  def test_from_dns_normalises
    mx = R.from_dns("Example.com.", "MX", "10 ALT3.aspmx.l.google.com.")
    assert_equal ["example.com", "MX", "alt3.aspmx.l.google.com", 10], mx.key
    assert_equal %(0 issue "letsencrypt.org"), R.from_dns("example.com", "CAA", "0 issue letsencrypt.org").content
    caa_row = R.from_cloudflare("name" => "example.com", "type" => "CAA", "data" => { "flags" => 0, "tag" => "issue", "value" => "letsencrypt.org" })
    assert_equal R.from_dns("example.com", "CAA", %(0 issue "letsencrypt.org")).key, caa_row.key
  end

  def test_desired_replaces_the_apex_and_www_and_copies_the_rest_dns_only
    snap = [rec("example.com", "A", "198.185.159.144"), rec("www.example.com", "CNAME", "ext-sq.squarespace.com"),
            rec("example.com", "MX", "smtp.google.com", priority: 1), rec("send.example.com", "TXT", "v=spf1 include:amazonses.com ~all")]
    want = R.desired("example.com", snap, "owl.herokudns.com.")

    assert_includes want.map(&:to_s), "example.com CNAME owl.herokudns.com (DNS only)"
    assert_includes want.map(&:to_s), "www.example.com CNAME example.com (proxied)"
    assert_includes want.map(&:to_s), "example.com MX 1 smtp.google.com (DNS only)"
    assert_includes want.map(&:to_s), %(send.example.com TXT "v=spf1 include:amazonses.com ~all" (DNS only))
    refute(want.any? { |r| r.type == "A" })
  end

  def test_reconcile_deletes_only_conflicts_fixes_proxy_and_keeps_extras
    want = R.desired("example.com", [rec("example.com", "MX", "smtp.google.com", priority: 1)], "owl.herokudns.com")
    current = [rec("example.com", "A", "198.185.159.144", proxied: true, id: "a1"),
               rec("example.com", "MX", "smtp.google.com", priority: 1, proxied: false, id: "m1"),
               rec("www.example.com", "CNAME", "example.com", proxied: false, id: "w1"),
               rec("legacy.example.com", "A", "192.0.2.1", proxied: false, id: "l1")]
    diff = R.reconcile(want, current)

    assert_equal ["a1"], diff[:delete].map(&:id), "the apex A conflicts with the apex CNAME"
    assert_equal [["w1", true]], diff[:update].map { |r| [r.id, r.proxied] }
    assert_equal ["example.com CNAME owl.herokudns.com (DNS only)"], diff[:create].map(&:to_s)
    assert_equal ["l1"], diff[:extra].map(&:id), "a record the snapshot missed is kept, not deleted"
    assert_equal ["example.com CNAME owl.herokudns.com (DNS only)", "www.example.com CNAME example.com (proxied)"],
                 R.missing(want, current).map(&:to_s), "absent, and present with the wrong proxy flag"
  end

  # ── guides ───────────────────────────────────────────────────────────────
  def guide(key, ds:, to: "alex", registrar: "Some Registrar")
    DC::Guide.new(registrar_key: key, registrar: registrar, domain: "example.com",
                  nameservers: %w[ada.ns.cloudflare.com bob.ns.cloudflare.com], ds_present: ds, to: to).render
  end

  def test_guide_has_the_dnssec_outage_step_only_when_a_ds_is_published
    with = guide("squarespace", ds: true)
    without = guide("squarespace", ds: false)

    assert_includes with, "scheduled outage"
    assert_includes with, "DNS** -> **DNSSEC"
    assert_includes with, "Step 2: Use Cloudflare's nameservers"
    refute_includes without, "DNSSEC"
    refute_includes without, "outage"
    assert_includes without, "Step 1: Use Cloudflare's nameservers"
    assert_includes without, "Use custom nameservers"
    assert_includes without, "reads **example.com** before you save"
  end

  def test_each_registrar_has_its_guide_and_unknown_falls_back
    %w[squarespace godaddy namecheap porkbun cloudflare].each { |k| assert_equal k, DC::Guide.key_for(k) }
    assert_equal "other", DC::Guide.key_for("gandi")
    %w[godaddy namecheap porkbun other].each { |k| assert_includes guide(k, ds: false), "Verify on first use" }
    refute_includes guide("squarespace", ds: false), "Verify on first use"
    cf = guide("cloudflare", ds: false)
    assert_includes cf, "No clicks needed"
    assert_includes cf, "anywhere except Cloudflare Registrar"
  end

  def test_guide_addresses_alex_or_the_client
    assert_includes guide("squarespace", ds: false), "YOUR TURN"
    assert_includes guide("other", ds: false, registrar: "Gandi SAS"), "Sign in to Gandi SAS"
    client = guide("squarespace", ds: true, to: "client", registrar: "Squarespace Domains II LLC")
    assert_includes client, "You keep owning example.com at Squarespace"
    assert_includes client, "tell McRitchie Studio"
    assert_raises(DC::Abort) { guide("squarespace", ds: false, to: "bob") }
  end

  # ── workspace ────────────────────────────────────────────────────────────
  def test_spf_merges_into_one_record
    assert_equal "v=spf1 include:_spf.google.com ~all", DC::Workspace.merged_spf(nil)
    assert_equal "v=spf1 include:amazonses.com include:_spf.google.com -all",
                 DC::Workspace.merged_spf("v=spf1 include:amazonses.com -all")
    same = "v=spf1 include:_spf.google.com include:x ~all"
    assert_equal same, DC::Workspace.merged_spf(same)
  end

  def test_workspace_plan_writes_google_mail_and_prompts_for_dkim
    out = DC::Workspace.plan("example.com", [], verification: "abc", rua: "mailto:d@example.com")

    created = out[:changes].map { |c| c.record.to_s }
    assert_includes created, %(example.com TXT "google-site-verification=abc")
    assert_includes created, "example.com MX 1 aspmx.l.google.com"
    assert_includes created, "example.com MX 10 alt4.aspmx.l.google.com"
    assert_includes created, %(_dmarc.example.com TXT "v=DMARC1; p=none; rua=mailto:d@example.com")
    assert_equal 5, out[:changes].count { |c| c.record.type == "MX" }
    assert(out[:notes].any? { |n| n.include?("admin.google.com") }, "no --dkim: the Google Admin prompt prints")
  end

  def test_workspace_plan_conflicts_without_replace_mail
    current = [rec("example.com", "MX", "mx.fastmail.com", priority: 10, id: "m"),
               rec("google._domainkey.example.com", "TXT", "v=DKIM1; p=OLD", id: "k")]
    out = DC::Workspace.plan("example.com", current, verification: nil, dkim: "v=DKIM1; p=NEW")
    assert_equal 2, out[:conflicts].size
    replaced = DC::Workspace.plan("example.com", current, verification: nil, dkim: "v=DKIM1; p=NEW", replace_mail: true)
    assert_empty replaced[:conflicts]
    assert(replaced[:changes].any? { |c| c.op == :delete && c.record.id == "m" })
    assert(replaced[:changes].any? { |c| c.op == :replace && c.content == "v=DKIM1; p=NEW" })
  end

  def test_google_single_mx_counts_as_google
    out = DC::Workspace.plan("example.com", [rec("example.com", "MX", "smtp.google.com", priority: 1)], verification: nil)
    assert_empty out[:conflicts]
    refute(out[:changes].any? { |c| c.record.type == "MX" })
  end

  # ── finalize's six hours ────────────────────────────────────────────────
  def test_finalize_refuses_before_six_hours_without_touching_an_api
    Dir.mktmpdir do |dir|
      store = DC::StateStore.new(dir)
      seen = Time.utc(2026, 10, 13, 18, 0, 0)
      store.save("example.com", "app" => "a", "domain" => "example.com", "phase" => "verified",
                                "zone_id" => "z", "nameservers" => [], "ns_seen_at" => seen.iso8601)
      exploding = Object.new.tap { |o| o.define_singleton_method(:method_missing) { |*| flunk "an API was called" } }
      runner = DC::Runner.new(app: "a", domain: "example.com", cloudflare: exploding, heroku: exploding,
                              doh: exploding, rdap: exploding, store: store, out: StringIO.new,
                              clock: -> { seen + 21_599 })

      err = assert_raises(DC::Abort) { runner.finalize }
      assert_match(/REFUSED until 2026-10-14T00:00:00Z/, err.message)
      assert_match(/Nothing was written/, err.message)
    end
  end

  def test_finalize_refuses_when_verify_never_saw_the_nameservers
    Dir.mktmpdir do |dir|
      store = DC::StateStore.new(dir)
      store.save("example.com", "phase" => "planned", "zone_id" => "z", "ns_seen_at" => nil)
      runner = DC::Runner.new(app: "a", domain: "example.com", cloudflare: nil, heroku: nil, doh: nil, rdap: nil,
                              store: store, out: StringIO.new)
      assert_match(/verify has not yet seen/, assert_raises(DC::Abort) { runner.finalize }.message)
    end
  end

  # ── the Cloudflare nameserver pattern matches DnsHost's ─────────────────
  def test_cloudflare_ns_pattern_matches_dns_host
    src = File.read(File.expand_path("../../app/models/dns_host.rb", __dir__))
    assert_includes src, %("cloudflare" => [ "Cloudflare", #{DC::Runner::CLOUDFLARE_NS.inspect} ]),
                    "DnsHost's Cloudflare pattern changed; keep Runner::CLOUDFLARE_NS the same"
    assert DC::Runner.cloudflare_ns?(%w[ada.ns.cloudflare.com. BOB.NS.CLOUDFLARE.COM])
    refute DC::Runner.cloudflare_ns?(%w[ada.ns.cloudflare.com nsa1.squarespacedns.com])
    refute DC::Runner.cloudflare_ns?([])
  end

  # ── credentials ─────────────────────────────────────────────────────────
  def test_heroku_key_prefers_the_shell_and_never_reads_1password_then
    reader = ->(*) { flunk "1Password read although HEROKU_API_KEY is set" }
    assert_equal "k-from-env", DC::Credentials.heroku(reader, env: { "HEROKU_API_KEY" => "k-from-env" })
  end

  def test_cloudflare_credentials_need_the_admin_lane
    saved = ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")
    err = assert_raises(DC::Abort) { DC::Credentials.cloudflare(->(*) { flunk "read without a token" }) }
    assert_match(/cloudflare.studio.provision/, err.message)
  ensure
    ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = saved if saved
  end

  def test_cloudflare_reads_the_item_by_name_on_the_admin_lane
    saved = ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"]
    ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = "ops_admin"
    refs = []
    token, account = DC::Credentials.cloudflare(lambda { |ref, env|
      refs << [ref, env["OP_SERVICE_ACCOUNT_TOKEN"]]
      ref.end_with?("api-token") ? "tok" : "acct"
    })
    assert_equal %w[tok acct], [token, account]
    vault = OpVaults.vault(:deployer) # studio-agents-admin unless MCR_OP_VAULT_ADMIN overrides it
    assert_equal [["op://#{vault}/cloudflare.studio.provision/api-token", "ops_admin"],
                  ["op://#{vault}/cloudflare.studio.provision/account-id", "ops_admin"]], refs
  ensure
    saved ? ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = saved : ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")
  end

  def test_redact_scrubs_secrets
    assert_equal "Bearer [REDACTED] failed", DC.redact("Bearer sekrit-token failed", ["sekrit-token", nil])
  end
end
