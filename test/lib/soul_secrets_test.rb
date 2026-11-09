# frozen_string_literal: true

# [unit] bin/lib/soul_secrets.rb — each soul's own set of 1Password items, warmed
# into <cache>/<soul>/ and read from there (config/soul_secret_sets.yml).
#
# Every case runs against a tmpdir cache (CLAUDE_PROJECTS_DIR, sandbox armed) and a
# stub `op` (SECRET_OP_BIN) that prints FAKE values. Nothing here reads 1Password
# or touches the operator's real <projects>/.secret-cache.
#
#   ruby -Itest test/lib/soul_secrets_test.rb

require "minitest/autorun"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "time"
require "stringio"
require "open3"
require_relative "../../bin/lib/soul_secrets"
require_relative "../../bin/lib/secret_cache_cli"

class SoulSecretsTest < Minitest::Test
  REAL_CONFIG = File.expand_path("../../config/soul_secret_sets.yml", __dir__)
  SOULS_YML = File.expand_path("../../config/souls.yml", __dir__)
  FAKE_KEY = "FAKE-PRIVATE-KEY-not-a-secret"
  FAKE_ADDR = "FAKEADDRESSnotawallet"
  FAKE_TOKEN = "fake-avi-service-account-token"

  CONFIG = {
    "souls" => {
      "avi" => {
        "service_account" => { "token_env" => "OP_SERVICE_ACCOUNT_TOKEN_AVI" },
        "items" => [{ "item" => "solana.mack.agent", "lane" => "agent",
                      "fields" => ["private-key", "wallet-address"], "lifetime" => "1d", "refresh_window" => "2h",
                      "readers" => ["bin/release"] }]
      },
      "steffon" => {
        "service_account" => { "token_env" => "OP_SERVICE_ACCOUNT_TOKEN_STEFFON" },
        "items" => [{ "item" => "heroku.studio.agents", "lane" => "agent", "fields" => ["credential"],
                      "lifetime" => "12h", "readers" => ["bin/lib/heroku_token.rb"] }]
      },
      "pokemon" => { "items" => [] }
    },
    "admin_tier" => { "lane" => "deployer", "storage" => "memory", "lifetime" => "15m",
                      "scripts" => ["bin/allowed-admin-script"] }
  }.freeze

  def setup
    OpMeter.reset_hang!
    SoulSecrets::Admin.reset!
    # No child inherits a real credential: every *_TOKEN leaves ENV for the test.
    @saved_tokens = ENV.to_h.select { |k, _| k.include?("TOKEN") }
    @saved_tokens.each_key { |k| ENV.delete(k) }
    @root = Dir.mktmpdir("soul-secrets-unit")
    @home = File.join(@root, ".secret-cache")
    @op_log = File.join(@root, "op-calls.log")
    @reads_log = File.join(@root, "op-reads.log")
    @config = File.join(@root, "sets.yml")
    File.write(@config, YAML.dump(CONFIG))
  end

  def teardown
    FileUtils.rm_rf(@root)
    @saved_tokens.each { |k, v| ENV[k] = v }
  end

  def op(body)
    path = File.join(@root, "op")
    # The stub NEVER echoes a token: the ambient OP_SERVICE_ACCOUNT_TOKEN is a real
    # credential the child inherits. It says only whether the token is one of
    # the fakes this file issues.
    File.write(path, <<~SH)
      #!/bin/sh
      case "${OP_SERVICE_ACCOUNT_TOKEN:-}" in
        #{FAKE_TOKEN}) who=avi-fake ;;
        fake-admin-token) who=admin-fake ;;
        "") who=none ;;
        *) who=ambient ;;
      esac
      echo "$* token=$who" >> #{@op_log}
      #{body}
    SH
    File.chmod(0o755, path)
    path
  end

  ITEM_JSON = JSON.generate("fields" => [{ "label" => "private-key", "value" => FAKE_KEY },
                                         { "label" => "wallet-address", "value" => FAKE_ADDR },
                                         { "label" => "notesPlain", "value" => "DROPPED-FIELD-VALUE" }])

  def answering_op
    op("cat <<'JSON'\n#{ITEM_JSON}\nJSON")
  end

  def hanging_op
    op("exec sleep 30")
  end

  def env(op_bin = answering_op, extra = {})
    { "CLAUDE_PROJECTS_DIR" => @root, "TASK_USAGE_SANDBOX" => "1", "SECRET_OP_BIN" => op_bin,
      "MCR_SOUL_SECRET_SETS" => @config, "MCR_OP_READS_LOG" => @reads_log, "MCR_OP_DEADLINE" => "1",
      "MCR_SECRET_CACHE_DIR" => nil, "OP_SERVICE_ACCOUNT_TOKEN_AVI" => nil }.merge(extra)
  end

  def cfg(e = env)
    SoulSecrets.config(e)
  end

  def op_calls
    File.exist?(@op_log) ? File.read(@op_log).lines : []
  end

  # Every file the tooling wrote, except the value files themselves.
  def every_file_text
    written = Dir.glob(File.join(@home, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }
    (written.reject { |f| File.basename(f).start_with?("item.") } + [@reads_log].select { |f| File.file?(f) })
      .map { |f| File.read(f) }.join("\n")
  end

  # ── the real config ─────────────────────────────────────────────────────────

  def test_unit_the_real_config_loads_and_names_a_set_for_every_roster_soul
    data = SoulSecrets.config("MCR_SOUL_SECRET_SETS" => REAL_CONFIG)
    roster = YAML.safe_load(File.read(SOULS_YML))["souls"].map { |s| s["slug"] }

    assert_equal roster.sort, data["souls"].keys.sort, "every soul in config/souls.yml has a set, even an empty one"
    %w[steffon avi alex turf-monster mack pokemon carl].each { |soul| assert data["souls"].key?(soul), soul }
    assert_equal %w[solana.mack.agent solana.turf.agent],
                 data["souls"]["avi"]["items"].map { |e| e["item"] }.sort, "the gauntlet's two wallets are Avi's"
    assert_equal "memory", data["admin_tier"]["storage"]
  end

  def test_unit_an_admin_vault_item_in_a_soul_set_is_refused_at_load
    bad = Marshal.load(Marshal.dump(CONFIG))
    bad["souls"]["avi"]["items"] << { "item" => "solana.turf.server", "lane" => "deployer",
                                      "fields" => ["private-key"], "lifetime" => "1h" }
    File.write(@config, YAML.dump(bad))

    error = assert_raises(SoulSecrets::ConfigError) { cfg }
    assert_includes error.message, "admin vault"
  end

  # The config names a lane, never a vault: the vault follows bin/lib/op_vaults.rb.
  def test_unit_an_items_vault_resolves_from_its_lane_and_honours_the_override
    assert_equal "studio-agents", cfg["souls"]["avi"]["items"][0]["vault"]
    moved = env(answering_op, "MCR_OP_VAULT_AGENT" => "renamed-agents")
    assert_equal "renamed-agents", SoulSecrets.manifest("avi", cfg(moved))["items"][0]["vault"]
    refute_match(/^\s*vault:/, File.read(REAL_CONFIG), "the real config names lanes, not vault literals")

    bad = Marshal.load(Marshal.dump(CONFIG))
    bad["souls"]["avi"]["items"][0]["lane"] = "nope"
    File.write(@config, YAML.dump(bad))
    assert_raises(SoulSecrets::ConfigError) { cfg }
  end

  def test_unit_an_item_must_name_the_fields_it_keeps_and_a_lifetime
    bad = Marshal.load(Marshal.dump(CONFIG))
    bad["souls"]["avi"]["items"][0].delete("fields")
    File.write(@config, YAML.dump(bad))
    assert_raises(SoulSecrets::ConfigError) { cfg }

    bad["souls"]["avi"]["items"][0]["fields"] = ["x"]
    bad["souls"]["avi"]["items"][0]["lifetime"] = "forever"
    File.write(@config, YAML.dump(bad))
    assert_raises(SoulSecrets::ConfigError) { cfg }
  end

  def test_unit_a_disk_admin_tier_is_refused_until_its_threat_is_answered
    bad = Marshal.load(Marshal.dump(CONFIG))
    bad["admin_tier"]["storage"] = "disk"
    File.write(@config, YAML.dump(bad))

    error = assert_raises(SoulSecrets::ConfigError) { cfg }
    assert_includes error.message, "not implemented"
  end

  # ── warm ───────────────────────────────────────────────────────────────────

  def test_unit_warm_writes_a_0600_file_in_a_0700_soul_folder_keeping_only_the_named_fields
    e = env
    lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e)

    assert ok, lines.join("\n")
    dir = File.join(@home, "avi")
    file = File.join(dir, "item.solana.mack.agent.json")
    assert_equal 0o700, File.stat(dir).mode & 0o777
    assert_equal 0o600, File.stat(file).mode & 0o777
    kept = JSON.parse(File.read(file))["fields"]
    assert_equal({ "private-key" => FAKE_KEY, "wallet-address" => FAKE_ADDR }, kept)
    refute_includes File.read(file), "DROPPED-FIELD-VALUE", "a field the set does not name never lands on disk"
    refute_includes lines.join("\n"), FAKE_KEY
    assert_match(/warmed, expires in 24 h/, lines.join("\n"))
    assert_equal 1, op_calls.size, "one op pass for one item"
  end

  def test_unit_a_second_warm_of_a_fresh_set_reads_no_1password
    e = env
    m = SoulSecrets.manifest("avi", cfg(e))
    SoulSecrets.warm(m, env: e)
    lines, ok = SoulSecrets.warm(m, env: e)

    assert ok
    assert_equal 1, op_calls.size
    assert_match(/fresh, expires in .*no 1Password read/, lines.join("\n"))
  end

  def test_unit_warm_inside_the_refresh_window_reads_again
    e = env
    m = SoulSecrets.manifest("avi", cfg(e))
    SoulSecrets.warm(m, env: e, now: Time.now - (23 * 3600))
    SoulSecrets.warm(m, env: e)

    assert_equal 2, op_calls.size, "an hour left is inside the 2 h window"
  end

  def test_unit_warm_uses_the_souls_own_service_account_when_it_is_set
    e = env(answering_op, "OP_SERVICE_ACCOUNT_TOKEN_AVI" => FAKE_TOKEN)
    lines, = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e)

    assert_includes op_calls.first, "token=avi-fake"
    assert_includes lines.first, "OP_SERVICE_ACCOUNT_TOKEN_AVI (this soul's own service account)"
    refute_includes lines.join, FAKE_TOKEN
  end

  def test_unit_warm_without_the_souls_token_says_it_used_the_shared_account
    e = env
    lines, = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e)

    assert_includes lines.first, "the shared agent service account (OP_SERVICE_ACCOUNT_TOKEN_AVI is not set)"
  end

  def test_unit_a_hung_op_fails_the_warm_in_seconds
    e = env(hanging_op)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e)

    refute ok
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
    assert_match(/FAILED: 1Password is not answering/, lines.join("\n"))
  end

  def test_unit_the_op_deadline_is_capped_at_twenty_seconds
    assert_equal "20", SoulSecrets.bounded_env("MCR_OP_DEADLINE" => "600")[OpMeter::DEADLINE_ENV]
    assert_equal "14", SoulSecrets.bounded_env({})[OpMeter::DEADLINE_ENV]
  end

  # ── read: the soul's own set, and the refusal ──────────────────────────────

  def test_unit_after_warm_a_read_hits_the_cache_even_when_op_hangs
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env)
    e = env(hanging_op)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fields = SoulSecrets.read("avi", "studio-agents", "solana.mack.agent", cfg: cfg(e), env: e)

    assert_equal FAKE_KEY, fields["private-key"]
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    assert_equal 1, op_calls.size, "the hanging op was never called"
    assert_includes File.read(@reads_log), "cache-hit"
  end

  def test_unit_a_soul_reading_another_souls_item_is_refused_and_logged
    e = env
    error = assert_raises(SoulSecrets::Refused) do
      SoulSecrets.read("pokemon", "studio-agents", "solana.mack.agent", cfg: cfg(e), env: e)
    end

    assert_includes error.message, "pokemon may not read studio-agents/solana.mack.agent"
    assert_includes error.message, "avi's set"
    assert_empty op_calls, "a refused read never reaches 1Password"
    row = File.read(@reads_log).lines.last.split("\t")
    assert_equal %w[soul-refused refused soul:pokemon:studio-agents/solana.mack.agent], row[2, 3]
  end

  def test_unit_a_soul_cannot_read_another_souls_warmed_copy
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env)
    assert_raises(SoulSecrets::Refused) do
      SoulSecrets.read("steffon", "studio-agents", "solana.mack.agent", cfg: cfg, env: env)
    end
  end

  def test_unit_an_item_no_set_names_is_not_managed
    assert_nil SoulSecrets.read("avi", "studio-agents", "some.other.item", cfg: cfg, env: env)
    assert_empty op_calls
  end

  def test_unit_a_failed_refresh_inside_the_window_serves_the_cached_copy
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env, now: Time.now - (23 * 3600))
    e = env(hanging_op)
    err = StringIO.new
    fields = SoulSecrets.read("avi", "studio-agents", "solana.mack.agent", cfg: cfg(e), env: e, err: err)

    assert_equal FAKE_ADDR, fields["wallet-address"]
    assert_includes err.string, "serving the cached copy"
    refute_includes err.string, FAKE_KEY
  end

  def test_unit_an_expired_copy_with_a_hung_op_is_unavailable
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env, now: Time.now - (25 * 3600))
    e = env(hanging_op)
    assert_raises(SoulSecrets::Unavailable) do
      SoulSecrets.read("avi", "studio-agents", "solana.mack.agent", cfg: cfg(e), env: e, err: StringIO.new)
    end
  end

  def test_unit_a_widened_soul_folder_is_refused
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env)
    File.chmod(0o755, File.join(@home, "avi"))

    assert_raises(SecretCache::Unsafe) do
      SoulSecrets.read("avi", "studio-agents", "solana.mack.agent", cfg: cfg, env: env)
    end
  end

  def test_unit_the_write_path_refuses_an_admin_vault_item_too
    entry = { "item" => "x", "vault" => "studio-agents-admin", "lifetime_seconds" => 60 }
    assert_raises(SecretCache::AdminVaultRefused) { SoulSecrets.store("avi", entry, { "a" => "b" }, env: env) }
    refute File.exist?(File.join(@home, "avi", "item.x.json"))
  end

  # ── the portable unit (ruling 2) ───────────────────────────────────────────

  def test_unit_a_fresh_machine_warms_from_the_manifest_file_alone
    manifest_file = File.join(@root, "avi.manifest.json")
    File.write(manifest_file, JSON.generate(SoulSecrets.manifest("avi", cfg)))
    e = env(answering_op, "MCR_SOUL_SECRET_SETS" => File.join(@root, "absent.yml"),
                          "OP_SERVICE_ACCOUNT_TOKEN_AVI" => FAKE_TOKEN)

    lines, ok = SoulSecrets.warm(SoulSecrets.load_manifest(manifest_file, e), env: e)

    assert ok, lines.join("\n")
    assert_includes op_calls.first, "token=avi-fake"
    assert File.file?(File.join(@home, "avi", "item.solana.mack.agent.json"))
    text = File.read(manifest_file)
    refute_includes text, FAKE_KEY
    refute_includes text, FAKE_TOKEN
  end

  # ── the CLI ────────────────────────────────────────────────────────────────

  def cli(args, e)
    out = StringIO.new
    err = StringIO.new
    code = SecretCacheCli.run(args.dup, env: e, out: out, err: err)
    [code, out.string, err.string]
  end

  def test_unit_cli_read_prints_one_field_and_item_json_prints_ops_shape
    e = env
    code, out, = cli(%w[read --soul avi studio-agents solana.mack.agent wallet-address], e)
    assert_equal 0, code
    assert_equal FAKE_ADDR, out

    code, out, = cli(%w[item-json --soul avi studio-agents solana.mack.agent], e)
    assert_equal 0, code
    labels = JSON.parse(out)["fields"].to_h { |f| [f["label"], f["value"]] }
    assert_equal FAKE_KEY, labels["private-key"]
  end

  def test_unit_cli_exit_codes_name_refused_and_not_managed
    e = env
    assert_equal SoulSecrets::REFUSED, cli(%w[read --soul pokemon studio-agents solana.mack.agent private-key], e)[0]
    assert_equal SecretCacheCli::NOT_MANAGED, cli(%w[read --soul avi studio-agents nope password], e)[0]
    assert_equal 2, cli(%w[read studio-agents solana.mack.agent private-key], e.merge("MCR_SOUL" => nil))[0]
  end

  # ── the plain read is closed (agent-op-reads-ratchet) ──────────────────────

  SECRET_BIN = File.expand_path("../../bin/secret", __dir__)

  # bin/secret as a process. Every *_TOKEN in the parent's env is dropped, so no
  # child inherits a real credential; the stub op never echoes its env.
  def secret_process(*args, e)
    secret_process_at(SECRET_BIN, *args, e)
  end

  def secret_process_at(bin, *args, e)
    scrub = ENV.keys.select { |k| k.include?("TOKEN") }.to_h { |k| [k, nil] }
    Open3.capture3(scrub.merge(e).merge("MCR_SOUL" => nil), bin, *args)
  end

  def test_unit_a_process_that_names_no_soul_cannot_read_a_soul_set_item
    e = env
    _out, err, status = secret_process("studio-agents", "solana.mack.agent", "private-key", e)

    assert_equal SoulSecrets::REFUSED, status.exitstatus
    assert_empty op_calls, "refused before any 1Password call"
    assert_match(/in avi's soul set/, err)
    assert_match(/MCR_SOUL=avi/, err, "the refusal names the fix")
    rows = OpMeter.records(env: e).select { |r| r["action"] == "soul-refused" }
    assert_equal ["soul:none:studio-agents/solana.mack.agent"], rows.map { |r| r["via"] }
    refute_includes err, FAKE_KEY
  end

  def test_unit_a_process_that_names_no_soul_still_reads_an_item_no_set_names
    e = env(op("echo plain-fake-value"))
    out, _err, status = secret_process("studio-agents", "x.studio.agents", "api-key", e)

    assert_equal 0, status.exitstatus
    assert_equal "plain-fake-value", out
    assert_equal 2, op_calls.size, "the classic whoami and read"
  end

  # The installed tooling runs bin/secret through a SYMLINKED bin/ (<projects>/.agents/bin
  # -> tooling/<sha>/bin). The sets config must resolve beside the REAL bin/, not the link.
  def test_unit_the_guard_finds_the_sets_config_through_a_symlinked_bin
    link = File.join(@root, "installed", "bin")
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(File.dirname(SECRET_BIN), link)
    e = env.merge("MCR_SOUL_SECRET_SETS" => nil)
    _out, err, status = secret_process_at(File.join(link, "secret"), "studio-agents", "solana.mack.agent",
                                          "private-key", e)

    assert_equal SoulSecrets::REFUSED, status.exitstatus, err
    assert_match(/in avi's soul set/, err, "the real config/soul_secret_sets.yml was read")
    assert_empty op_calls, "refused before any 1Password call"
  end

  # ── a second refusal is marked (agent-op-reads-ratchet) ─────────────────────

  def test_unit_a_second_refusal_marks_the_item_in_sets_until_a_read_rewrites_it
    e = env
    assert_raises(AuthRefresh::StillRefused) do
      SoulSecrets.with_refresh("avi", "studio-agents", "solana.mack.agent", service: "solana", cfg: cfg(e), env: e,
                               err: StringIO.new) { |_f| raise AuthRefresh::Rejected }
    end
    _code, sets, = cli(%w[sets], e)
    assert_match(%r{solana.mack.agent: expires in .*REFUSED by solana after a fresh read}, sets)
    refute_includes sets, FAKE_KEY

    SoulSecrets.forget("avi", "solana.mack.agent", env: e)
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e)
    _code, sets, = cli(%w[sets], e)
    refute_match(/REFUSED/, sets, "a fresh read rewrites the file without the mark")
  end

  def test_unit_cli_sets_and_manifest_print_no_value
    e = env
    cli(%w[warm avi], e)
    _code, sets, = cli(%w[sets], e)
    _code, manifest, = cli(%w[manifest avi], e)

    assert_match(%r{studio-agents/solana.mack.agent: expires in}, sets)
    assert_match(/pokemon: 0 item/, sets)
    assert_equal "avi", JSON.parse(manifest)["soul"]
    [sets, manifest, every_file_text].each do |text|
      refute_includes text, FAKE_KEY
      refute_includes text, FAKE_ADDR
    end
  end

  def test_unit_forget_source_drops_every_souls_copy
    e = env
    cli(%w[warm avi], e)
    code, out, = cli(%w[forget --source solana.mack.agent], e)

    assert_equal 0, code
    assert_includes out, "avi/solana.mack.agent: forgotten"
    refute File.exist?(File.join(@home, "avi", "item.solana.mack.agent.json"))
  end

  # ── the launch seam: the SubagentStart hook ───────────────────────────────

  def test_unit_the_hook_starts_a_warm_for_a_soul_whose_set_is_due
    started = []
    soul = SoulSecrets.hook(JSON.generate("hook_event_name" => "SubagentStart", "agent_type" => "avi"),
                            env: env, spawner: ->(s) { started << s })

    assert_equal "avi", soul
    assert_equal ["avi"], started
  end

  def test_unit_the_hook_starts_nothing_for_a_fresh_set_an_empty_set_or_an_unknown_agent
    SoulSecrets.warm(SoulSecrets.manifest("avi", cfg), env: env)
    started = []
    spawner = ->(s) { started << s }
    ["avi", "pokemon", "general-purpose", "Explore", "../etc"].each do |type|
      assert_nil SoulSecrets.hook(JSON.generate("agent_type" => type), env: env, spawner: spawner), type
    end
    assert_nil SoulSecrets.hook("not json", env: env, spawner: spawner)
    assert_empty started
  end

  # ── the admin tier (ruling 1) ─────────────────────────────────────────────

  def admin_root
    root = File.join(@root, "tooling")
    FileUtils.mkdir_p(File.join(root, "bin"))
    %w[allowed-admin-script other-script].each do |name|
      File.write(File.join(root, "bin", name), "#!/bin/sh\n")
    end
    root
  end

  def test_unit_admin_tier_refuses_a_script_off_the_allowlist_and_logs_it
    root = admin_root
    e = env(op("echo ADMIN-FAKE-VALUE"), "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-admin-token")
    assert_raises(SoulSecrets::Admin::Refused) do
      SoulSecrets::Admin.read("github.mcritchie-admin", "app-id", cfg: cfg(e), env: e,
                                                                 program: File.join(root, "bin", "other-script"), root: root)
    end
    assert_empty op_calls
    assert_includes File.read(@reads_log), "admin-refused"
  end

  def test_unit_admin_tier_reads_for_an_allowlisted_script_in_memory_and_writes_nothing
    root = admin_root
    e = env(op("echo ADMIN-FAKE-VALUE"), "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-admin-token")
    program = File.join(root, "bin", "allowed-admin-script")
    2.times do
      value = SoulSecrets::Admin.read("github.mcritchie-admin", "app-id", cfg: cfg(e), env: e, program: program, root: root)
      assert_equal "ADMIN-FAKE-VALUE", value
    end

    assert_equal 1, op_calls.size, "the second read is the process's memory"
    assert_includes op_calls.first, "op://studio-agents-admin/github.mcritchie-admin/app-id"
    assert_includes op_calls.first, "token=admin-fake"
    refute File.exist?(@home), "the admin tier writes nothing to the cache folder"
  end
end
