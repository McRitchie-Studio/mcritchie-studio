# frozen_string_literal: true

# [unit] bin/lib/auth_refresh.rb and its callers: one fresh read and one retry
# after a refused credential; a second refusal stops and names the item. Also the
# per-soul warm lock. Every value is FAKE; the stubs never echo their env; setup
# strips OP_SERVICE_ACCOUNT_TOKEN and every *_TOKEN from ENV so no child inherits
# a real one; each test asserts no fake value reaches stderr or the read log.
#
#   ruby -Itest test/lib/auth_refresh_test.rb

require "minitest/autorun"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "stringio"
require "rbconfig"
require_relative "../../bin/lib/auth_refresh"
require_relative "../../bin/lib/soul_secrets"
require_relative "../../bin/lib/gh_auth_retry"

class AuthRefreshTest < Minitest::Test
  CLI = File.expand_path("../../bin/lib/secret_cache_cli.rb", __dir__)
  OLD_KEY = "FAKE-OLD-KEY-rotated-away"
  NEW_KEY = "FAKE-NEW-KEY-after-rotation"
  FAKE_MINTED = "fake-minted-token-not-real"

  CONFIG = {
    "souls" => {
      "steffon" => {
        "items" => [{ "item" => "heroku.studio.agents", "lane" => "agent", "fields" => ["credential"],
                      "lifetime" => "12h", "readers" => ["bin/lib/heroku_token.rb"] }]
      },
      "avi" => {
        "items" => [{ "item" => "solana.mack.agent", "lane" => "agent", "fields" => ["private-key"],
                      "lifetime" => "1d", "refresh_window" => "2h" }]
      }
    }
  }.freeze

  def setup
    OpMeter.reset_hang!
    @saved_env = ENV.to_h.select { |k, _| k == "OP_SERVICE_ACCOUNT_TOKEN" || k.end_with?("_TOKEN") || k.include?("_TOKEN_") }
    @saved_env.each_key { |k| ENV.delete(k) }
    @root = Dir.mktmpdir("auth-refresh-unit")
    @op_log = File.join(@root, "op-calls.log")
    @reads_log = File.join(@root, "op-reads.log")
    @config = File.join(@root, "sets.yml")
    @key_file = File.join(@root, "served-key")
    File.write(@config, YAML.dump(CONFIG))
    serve(OLD_KEY)
  end

  def teardown
    FileUtils.rm_rf(@root)
    @saved_env.each { |k, v| ENV[k] = v }
  end

  # The value the stub op serves. Changing it is "a rotation in 1Password".
  def serve(key)
    File.write(@key_file, key)
  end

  # The stub op: logs its argv words (never its env), then prints the item with
  # the value from @key_file. +before+ runs first (the warm-lock test blocks there).
  def op_bin(before: "", name: "op")
    path = File.join(@root, name)
    File.write(path, <<~SH)
      #!/bin/sh
      echo "$1 $2 $3" >> #{@op_log}
      #{before}
      key="$(cat #{@key_file})"
      printf '{"fields":[{"label":"credential","value":"%s"},{"label":"private-key","value":"%s"}]}\\n' "$key" "$key"
    SH
    File.chmod(0o755, path)
    path
  end

  def env(extra = {})
    { "CLAUDE_PROJECTS_DIR" => @root, "TASK_USAGE_SANDBOX" => "1", "SECRET_OP_BIN" => op_bin,
      "MCR_SOUL_SECRET_SETS" => @config, "MCR_OP_READS_LOG" => @reads_log, "MCR_OP_DEADLINE" => "5",
      "MCR_SECRET_CACHE_DIR" => nil, "OP_SERVICE_ACCOUNT_TOKEN" => nil,
      "OP_SERVICE_ACCOUNT_TOKEN_STEFFON" => nil, "OP_SERVICE_ACCOUNT_TOKEN_AVI" => nil }.merge(extra)
  end

  def cfg(e = env)
    SoulSecrets.config(e)
  end

  def vault(e = env)
    SoulSecrets.lane_vault("agent", e)
  end

  def op_calls
    File.exist?(@op_log) ? File.read(@op_log).lines.grep(/\Aitem get/) : []
  end

  def refresh_rows
    OpMeter.records(env: env).select { |r| r["action"] == AuthRefresh::ACTION }
  end

  def refute_leaks(*texts)
    blob = (texts + [File.exist?(@reads_log) ? File.read(@reads_log) : ""]).join("\n")
    [OLD_KEY, NEW_KEY, FAKE_MINTED].each { |value| refute_includes blob, value, "a value reached output or a log" }
  end

  # A Heroku-shaped service: it accepts only the current key and answers 401 to
  # any other. The block raises Rejected on the 401, as a real client would.
  def heroku(fields, calls)
    calls << :call
    raise AuthRefresh::Rejected unless fields["credential"] == File.read(@key_file)

    "200 OK"
  end

  # ── the acceptance case: a rotated key ─────────────────────────────────────

  def test_unit_a_stale_cached_key_gets_401_refreshes_once_and_succeeds
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    serve(NEW_KEY) # rotated in 1Password; the cache still holds the old key
    File.delete(@op_log)
    calls = []
    err = StringIO.new

    answer = SoulSecrets.with_refresh("steffon", vault(e), "heroku.studio.agents", service: "heroku",
                                      cfg: cfg(e), env: e, err: err) { |fields| heroku(fields, calls) }

    assert_equal "200 OK", answer
    assert_equal 2, calls.size, "one refused call, one call with the fresh key"
    assert_equal 1, op_calls.size, "exactly one fresh read from 1Password"
    copy = SoulSecrets.cached("steffon", SoulSecrets.manifest("steffon", cfg(e))["items"].first, env: e)
    assert copy["fields"]["credential"] == NEW_KEY, "the fresh key replaced the stale one in the cache"
    assert_equal [%w[ok heroku:heroku.studio.agents]], refresh_rows.map { |r| [r["outcome"], r["via"]] }
    assert_includes err.string, "heroku refused heroku.studio.agents"
    refute_leaks(err.string)
  end

  def test_unit_a_still_bad_key_stops_after_one_refresh_and_names_the_item
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    File.delete(@op_log)
    calls = []
    err = StringIO.new

    error = assert_raises(AuthRefresh::StillRefused) do
      SoulSecrets.with_refresh("steffon", vault(e), "heroku.studio.agents", service: "heroku", cfg: cfg(e),
                                                                             env: e, err: err) do |fields|
        calls << :call
        raise AuthRefresh::Rejected if fields # the service refuses even the fresh copy
      end
    end

    assert_equal 2, calls.size, "two calls, never a third"
    assert_equal 1, op_calls.size, "one fresh read, never a second"
    assert_equal "heroku.studio.agents", error.item
    assert_equal "heroku", error.service
    assert_includes error.message, "heroku.studio.agents"
    assert_includes error.message, "stopping"
    assert_equal ["still-refused"], refresh_rows.map { |r| r["outcome"] }
    refute_leaks(err.string, error.message)
  end

  # A sibling process that met the same 401 refreshed first: its copy is used, and
  # this process spends no read of its own.
  def test_unit_a_copy_a_sibling_already_refreshed_costs_no_second_read
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    serve(NEW_KEY)
    File.delete(@op_log)
    calls = []
    entry = SoulSecrets.manifest("steffon", cfg(e))["items"].first

    answer = SoulSecrets.with_refresh("steffon", vault(e), "heroku.studio.agents", service: "heroku",
                                                                                     cfg: cfg(e), env: e, err: StringIO.new) do |fields|
      # The sibling writes the fresh copy while this call is in flight.
      SoulSecrets.store("steffon", entry, { "credential" => NEW_KEY }, env: e) if calls.empty?
      heroku(fields, calls)
    end

    assert_equal "200 OK", answer
    assert_empty op_calls, "the sibling's fresh copy is used; no read of this process's own"
  end

  # THE LOCK AROUND FORGET AND READ (Carl's note on secret-refresh-on-auth-failure).
  # While another process holds the soul's lock, a refresh neither forgets the
  # copy nor reads 1Password. When the holder writes no fresh copy within the
  # wait, the refresh fails (RefreshFailed upstream) and the copy is still there.
  def hold_soul_lock(soul, e)
    dir = SoulSecrets.ensure_soul_dir!(soul, e)
    lock = File.open(File.join(dir, SoulSecrets::WARM_LOCK), File::RDWR | File::CREAT, 0o600)
    assert lock.flock(File::LOCK_EX | File::LOCK_NB), "the test takes the lock first"
    lock
  end

  def test_unit_a_refresh_waits_for_the_souls_lock_and_reads_nothing_under_it
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    File.delete(@op_log)
    entry = SoulSecrets.manifest("steffon", cfg(e))["items"].first
    lock = hold_soul_lock("steffon", e)

    error = assert_raises(SoulSecrets::Unavailable) do
      SoulSecrets.refresh_locked("steffon", "heroku.studio.agents", entry, cfg: cfg(e), env: e,
                                 refused: { "credential" => OLD_KEY }, wait: 0.3)
    end
    assert_match(/held steffon's secret lock/, error.message)
    assert_empty op_calls, "no 1Password read while another process holds the lock"
    refute_nil SoulSecrets.cached("steffon", entry, env: e), "the copy was not forgotten outside the lock"
    refute_leaks(error.message)
  ensure
    lock&.close
  end

  def test_unit_a_refresh_that_waited_takes_the_holders_fresh_copy
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    File.delete(@op_log)
    entry = SoulSecrets.manifest("steffon", cfg(e))["items"].first
    lock = hold_soul_lock("steffon", e)
    # The holder (a sibling's refresh) has written the fresh copy.
    SoulSecrets.store("steffon", entry, { "credential" => NEW_KEY }, env: e)

    fields = SoulSecrets.refresh_locked("steffon", "heroku.studio.agents", entry, cfg: cfg(e), env: e,
                                        refused: { "credential" => OLD_KEY }, wait: 0.3)
    assert_equal({ "credential" => NEW_KEY }, fields)
    assert_empty op_calls
  ensure
    lock&.close
  end

  def test_unit_two_racing_refreshes_spend_one_read
    e = env
    SoulSecrets.warm(SoulSecrets.manifest("steffon", cfg(e)), env: e)
    serve(NEW_KEY)
    File.delete(@op_log)
    entry = SoulSecrets.manifest("steffon", cfg(e))["items"].first
    refused = { "credential" => OLD_KEY }

    threads = Array.new(2) do
      Thread.new { SoulSecrets.refresh_locked("steffon", "heroku.studio.agents", entry, cfg: cfg(e), env: e, refused: refused) }
    end
    assert_equal [{ "credential" => NEW_KEY }] * 2, threads.map(&:value)
    assert_equal 1, op_calls.size, "the second refresh found the first one's copy"
  end

  # A reader script reads its item from the soul whose set lists it as a reader.
  def test_unit_a_declared_reader_names_the_owning_soul
    e = env
    assert_equal "steffon", SoulSecrets.reader_owner(cfg(e), vault(e), "heroku.studio.agents", "bin/lib/heroku_token.rb")
    assert_nil SoulSecrets.reader_owner(cfg(e), vault(e), "heroku.studio.agents", "bin/something-else")
    assert_nil SoulSecrets.reader_owner(cfg(e), "another-vault", "heroku.studio.agents", "bin/lib/heroku_token.rb")
  end

  def test_unit_an_item_no_set_names_is_not_refreshed_here
    e = env
    assert_raises(SoulSecrets::Unavailable) do
      SoulSecrets.with_refresh("steffon", vault(e), "not.in.any.set", service: "x", cfg: cfg(e), env: e) { |_f| :never }
    end
    assert_raises(SoulSecrets::Refused) do
      SoulSecrets.with_refresh("steffon", vault(e), "solana.mack.agent", service: "x", cfg: cfg(e), env: e,
                                                                          err: StringIO.new) { |_f| :never }
    end
    assert_empty op_calls
  end

  # ── AuthRefresh itself ─────────────────────────────────────────────────────

  def run_refresh(results, refresh: -> { "fresh-fake" }, reads: [])
    queue = results.dup
    seen = []
    say = []
    result = AuthRefresh.run(item: "some.item", service: "svc", read: -> { "cached-fake" },
                             refresh: -> { reads << :read; refresh.call },
                             rejected: ->(r) { r == 401 }, env: env, say: ->(l) { say << l }) do |value|
      seen << value
      queue.shift
    end
    [result, seen, say]
  end

  # Not a blind retry: a failure that is not a credential refusal is returned
  # untouched, with no read and no second call.
  def test_unit_a_failure_that_is_not_a_refusal_is_returned_untouched
    reads = []
    result, seen, say = run_refresh([500, 200], reads: reads)

    assert_equal 500, result
    assert_equal ["cached-fake"], seen
    assert_empty reads
    assert_empty say
    assert_empty refresh_rows
  end

  def test_unit_a_refusal_reads_fresh_once_and_hands_the_block_the_fresh_value
    reads = []
    result, seen, say = run_refresh([401, 200], reads: reads)

    assert_equal 200, result
    assert_equal %w[cached-fake fresh-fake], seen
    assert_equal 1, reads.size
    assert_match(/svc refused some\.item/, say.first)
    assert_equal [%w[ok svc:some.item]], refresh_rows.map { |r| [r["outcome"], r["via"]] }
  end

  def test_unit_a_failed_fresh_read_stops_with_the_first_answer_and_is_logged
    error = assert_raises(AuthRefresh::RefreshFailed) do
      run_refresh([401, 200], refresh: -> { raise SoulSecrets::Unavailable, "1Password is not answering (some.item)" })
    end

    assert_equal 401, error.result, "the caller can still show what the service said"
    assert_includes error.message, "some.item"
    assert_includes error.message, "1Password is not answering"
    assert_equal ["refresh-failed"], refresh_rows.map { |r| r["outcome"] }
  end

  # A caller that passes a value where a name belongs cannot log it.
  def test_unit_the_log_carries_names_only
    AuthRefresh.record("ghs_#{'x' * 36}", "svc", "ok", env)
    AuthRefresh.record("a name\twith a tab", "svc", "ok", env)

    assert_equal ["svc:unnamed", "svc:unnamed"], refresh_rows.map { |r| r["via"] }
  end

  # ── GitHub: GhAuthRetry.with_refresh (bin/submit's gh calls) ───────────────

  # A broker that counts its calls in a file and prints a fake token. It never
  # echoes its env or argv.
  def broker(ok: true)
    path = File.join(@root, "gh-token-stub")
    count = File.join(@root, "broker-calls")
    body = ok ? "echo #{FAKE_MINTED}" : "echo 'op: not signed in' >&2; exit 1"
    File.write(path, "#!/bin/sh\necho call >> #{count}\n#{body}\n")
    File.chmod(0o755, path)
    [path, count]
  end

  def broker_calls(count)
    File.exist?(count) ? File.read(count).lines.size : 0
  end

  # gh refuses the ambient login with a 401 and accepts only +good+.
  def gh(token, good)
    token == good ? ["[]", true] : ["HTTP 401: Bad credentials (https://api.github.com/graphql)", false]
  end

  def test_unit_github_401_mints_once_and_retries_once
    path, count = broker
    say = []
    result = GhAuthRetry.with_refresh(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path),
                                      say: ->(l) { say << l }) { |token| gh(token, FAKE_MINTED) }

    assert_equal ["[]", true], result
    assert_equal 1, broker_calls(count)
    assert_equal [%w[ok github:github.mcritchie-agent]], refresh_rows.map { |r| [r["outcome"], r["via"]] }
    assert_match(/minting a GitHub App token/, say.join)
    refute_leaks(say.join)
  end

  def test_unit_github_refusing_the_fresh_token_stops_and_names_the_app_item
    path, count = broker
    error = assert_raises(AuthRefresh::StillRefused) do
      GhAuthRetry.with_refresh(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path),
                               say: ->(_l) { }) { |token| gh(token, "a-token-nobody-has") }
    end

    assert_equal 1, broker_calls(count), "one mint, never a second"
    assert_includes error.message, "github.mcritchie-agent"
    assert_match(/Bad credentials/, error.result.first, "gh's own answer survives for the caller")
    refute_leaks(error.message)
  end

  def test_unit_github_second_refusal_is_marked_in_status_and_an_accepted_refresh_clears_it
    path, = broker
    e = env("GH_AUTH_TOKEN_BIN" => path)
    assert_raises(AuthRefresh::StillRefused) do
      GhAuthRetry.with_refresh(identity: "agent", env: e, say: ->(_l) { }) { |token| gh(token, "a-token-nobody-has") }
    end
    assert_equal "github", SecretCache.entry("github.agent", e)["still_refused_by"]
    assert_match(/REFUSED by github after a fresh read/, SecretCache.status_lines(env: e).join("\n"))

    GhAuthRetry.with_refresh(identity: "agent", env: e, say: ->(_l) { }) { |token| gh(token, FAKE_MINTED) }
    refute SecretCache.entry("github.agent", e).key?("still_refused_at"), "an accepted refresh clears the mark"
    refute_leaks(SecretCache.status_lines(env: e).join("\n"))
  end

  def test_unit_github_mint_failure_keeps_ghs_original_answer
    path, count = broker(ok: false)
    error = assert_raises(AuthRefresh::RefreshFailed) do
      GhAuthRetry.with_refresh(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path),
                               say: ->(_l) { }) { |token| gh(token, FAKE_MINTED) }
    end

    assert_equal 1, broker_calls(count)
    assert_match(/Bad credentials/, error.result.first)
    assert_includes error.message, "not signed in", "the broker's reason is named"
  end

  def test_unit_github_a_non_auth_failure_mints_nothing
    path, count = broker
    result = GhAuthRetry.with_refresh(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path),
                                      say: ->(_l) { }) { |_t| ["merge conflict in CHANGELOG.md", false] }

    assert_equal ["merge conflict in CHANGELOG.md", false], result
    assert_equal 0, broker_calls(count)
  end

  INTEGRATION_403 = "GraphQL: Resource not accessible by integration (createPullRequest)"
  FAKE_LEAKED = "fake-leaked-deployer-token-not-real"

  # A 403 permission refusal of a token THIS PROCESS minted: a fresh token for the
  # same App is refused the same way, so no second mint.
  def test_unit_github_integration_403_of_our_own_minted_token_mints_nothing_more
    GhAuthRetry.forget_minted!
    path, count = broker
    e = env("GH_AUTH_TOKEN_BIN" => path)
    ours = GhAuthRetry.mint(identity: "agent", env: e)
    assert_equal 1, broker_calls(count)
    result = GhAuthRetry.with_refresh(identity: "agent", env: e, token: ours, say: ->(_l) { }) { |_t| [INTEGRATION_403, false] }

    assert_equal [INTEGRATION_403, false], result, "gh's answer is returned untouched"
    assert_equal 1, broker_calls(count), "no second mint, no fresh read from 1Password"
    assert_empty refresh_rows, "no auth-refresh row"
    refute GhAuthRetry.refreshable?(INTEGRATION_403, token: ours, env: {})
    assert GhAuthRetry.auth_failure?(INTEGRATION_403), "it still words as an auth failure for other readers"
  ensure
    GhAuthRetry.forget_minted!
  end

  # The leaked-deployer case (review of agent-op-reads-ratchet): an inherited GH_TOKEN
  # of ANOTHER App gets the 403 on `gh pr create`; minting the lane's App fixes it.
  def test_unit_github_integration_403_of_an_inherited_token_mints_and_retries
    GhAuthRetry.forget_minted!
    path, count = broker
    e = env("GH_AUTH_TOKEN_BIN" => path, "GH_TOKEN" => FAKE_LEAKED)
    result = GhAuthRetry.with_refresh(identity: "agent", env: e, say: ->(_l) { }) do |t|
      t == FAKE_MINTED ? ["https://github.com/o/r/pull/1", true] : [INTEGRATION_403, false]
    end

    assert_equal ["https://github.com/o/r/pull/1", true], result
    assert_equal 1, broker_calls(count)
    assert GhAuthRetry.refreshable?(INTEGRATION_403, token: nil, env: { "GH_TOKEN" => FAKE_LEAKED })
    refute_leaks(refresh_rows.to_s)
    refute_includes File.exist?(@reads_log) ? File.read(@reads_log) : "", FAKE_LEAKED
  ensure
    GhAuthRetry.forget_minted!
  end

  # Steffon's light on agent-op-reads-ratchet: the inherited token's 403 starts the
  # refresh, and the fresh token meets the SAME 403. The retry rides a token this
  # process minted, which refreshable? excuses; on the retry any credential refusal
  # counts, so the run stops StillRefused and logs `still-refused`, never `ok`.
  def test_unit_github_integration_403_on_the_retry_too_is_still_refused_not_ok
    GhAuthRetry.forget_minted!
    path, count = broker
    e = env("GH_AUTH_TOKEN_BIN" => path, "GH_TOKEN" => FAKE_LEAKED)
    error = assert_raises(AuthRefresh::StillRefused) do
      GhAuthRetry.with_refresh(identity: "agent", env: e, say: ->(_l) { }) { |_t| [INTEGRATION_403, false] }
    end

    assert_equal 1, broker_calls(count), "one mint, never a second"
    assert_equal [%w[still-refused github:github.mcritchie-agent]], refresh_rows.map { |r| [r["outcome"], r["via"]] }
    assert_equal [INTEGRATION_403, false], error.result, "gh's own answer survives for the caller"
    assert_equal "github", SecretCache.entry("github.agent", e)["still_refused_by"]
    refute_leaks(error.message, refresh_rows.to_s)
  ensure
    GhAuthRetry.forget_minted!
  end

  # CiStatus, and bin/release through it: the held (minted) token is ours; none held
  # means the ambient one, which may be another App's.
  def test_unit_ci_status_refusal_tells_our_minted_token_from_an_inherited_one
    require_relative "../../bin/lib/ci_status"
    GhAuthRetry.forget_minted!
    path, = broker
    ours = GhAuthRetry.mint(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path))

    refute CiStatus.gh_auth_refusal?(INTEGRATION_403, token: ours)
    assert CiStatus.gh_auth_refusal?(INTEGRATION_403, token: FAKE_LEAKED)
    assert CiStatus.gh_auth_refusal?("HTTP 401: Bad credentials", token: ours), "an expired token of ours still refreshes"
  ensure
    GhAuthRetry.forget_minted!
  end

  # The PAT fallback is a stale-credential shape: a minted App token fixes it.
  def test_unit_github_personal_access_token_403_still_refreshes
    path, count = broker
    refusal = "GraphQL: Resource not accessible by personal access token (createPullRequest)"
    result = GhAuthRetry.with_refresh(identity: "agent", env: env("GH_AUTH_TOKEN_BIN" => path),
                                      say: ->(_l) { }) { |t| t == FAKE_MINTED ? ["ok", true] : [refusal, false] }

    assert_equal ["ok", true], result
    assert_equal 1, broker_calls(count)
  end

  # ── the admin tier: a refresh in memory, never on disk ─────────────────────

  def admin_cfg(script)
    { "admin_tier" => { "lane" => "deployer", "storage" => "memory", "lifetime" => "15m", "scripts" => [script] } }
  end

  # The stub op for `op read`: logs its argv words, prints the served key.
  def admin_op_bin
    path = File.join(@root, "op-admin")
    File.write(path, "#!/bin/sh\necho \"$1\" >> #{@op_log}\ncat #{@key_file}\n")
    File.chmod(0o755, path)
    path
  end

  def admin_reads
    File.exist?(@op_log) ? File.read(@op_log).lines.grep(/\Aread/).size : 0
  end

  def test_unit_admin_refresh_stays_in_memory_and_reads_once
    SoulSecrets::Admin.reset!
    script = File.join(@root, "bin", "admin-script")
    FileUtils.mkdir_p(File.dirname(script))
    File.write(script, "")
    e = env("SECRET_OP_BIN" => admin_op_bin, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-admin-sa-not-real")
    cache_before = Dir.glob(File.join(@root, "**", "*")).sort
    calls = []
    first = SoulSecrets::Admin.read("heroku.studio.admin", "credential", cfg: admin_cfg("bin/admin-script"),
                                    env: e, program: script, root: @root)
    assert_equal OLD_KEY, first
    serve(NEW_KEY) # rotated; the memo still holds the old key
    err = StringIO.new
    answer = SoulSecrets::Admin.with_refresh("heroku.studio.admin", "credential", service: "heroku",
                                             cfg: admin_cfg("bin/admin-script"), env: e, program: script,
                                             root: @root, err: err) { |value| heroku({ "credential" => value }, calls) }

    assert_equal "200 OK", answer
    assert_equal 2, calls.size, "one refused call, one retry"
    assert_equal 2, admin_reads, "the first read and one fresh read; never a third"
    assert_equal [%w[ok heroku:heroku.studio.admin]], refresh_rows.map { |r| [r["outcome"], r["via"]] }
    written = Dir.glob(File.join(@root, "**", "*")).sort - cache_before - [@op_log, @reads_log]
    assert_empty written, "an admin refresh writes nothing to disk"
    refute_leaks(err.string)
  ensure
    SoulSecrets::Admin.reset!
  end

  def test_unit_admin_refresh_refuses_a_script_outside_the_tier_before_any_read
    SoulSecrets::Admin.reset!
    e = env("SECRET_OP_BIN" => admin_op_bin, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-admin-sa-not-real")
    assert_raises(SoulSecrets::Admin::Refused) do
      SoulSecrets::Admin.with_refresh("heroku.studio.admin", "credential", service: "heroku",
                                      cfg: admin_cfg("bin/admin-script"), env: e, program: __FILE__,
                                      root: @root, err: StringIO.new) { |_v| flunk "never called" }
    end
    assert_equal 0, admin_reads
  end

  # ── the per-soul warm lock ─────────────────────────────────────────────────

  def lock_path(e = env)
    File.join(SoulSecrets.soul_dir("avi", e), SoulSecrets::WARM_LOCK)
  end

  def test_unit_a_warm_finding_the_souls_lock_held_stops_and_reads_nothing
    e = env
    SoulSecrets.ensure_soul_dir!("avi", e)
    File.open(lock_path(e), File::RDWR | File::CREAT, 0o600) do |held|
      assert held.flock(File::LOCK_EX | File::LOCK_NB)
      lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e, wait: 0)

      assert ok, "the hook's warm (wait 0) is not a failure when another warm runs"
      assert_match(/holds the warm lock/, lines.join)
    end
    assert_empty op_calls
  end

  def test_unit_a_waiting_warm_gives_up_at_its_bound_and_says_the_set_is_still_due
    e = env
    SoulSecrets.ensure_soul_dir!("avi", e)
    File.open(lock_path(e), File::RDWR | File::CREAT, 0o600) do |held|
      held.flock(File::LOCK_EX)
      lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e, wait: 0.2)

      refute ok, "the set is still due after the bound"
      assert_match(/holds the warm lock/, lines.join)
    end
    assert_empty op_calls
  end

  # Two warms of one soul at once: the second finds the first holding the lock.
  # The first's `op` blocks on a FIFO the test opens only after the second warm
  # has returned, so the overlap is certain, not a race won by timing.
  def test_unit_two_concurrent_warms_of_one_soul_spend_one_read
    fifo = File.join(@root, "release")
    started = File.join(@root, "started")
    assert system("mkfifo", fifo)
    e = env("SECRET_OP_BIN" => op_bin(before: "touch #{started}; read line < #{fifo}", name: "op-blocking"), "MCR_OP_DEADLINE" => "20")
    child_env = e.merge("RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil)
    pid = Process.spawn(child_env, RbConfig.ruby, CLI, "warm", "avi", "--wait", "0",
                        out: File::NULL, err: File::NULL, in: File::NULL)
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until File.exist?(started)
        flunk "the first warm never reached op" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Thread.pass
      end

      lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e, wait: 0)
      assert ok
      assert_match(/holds the warm lock/, lines.join)
    ensure
      # The stub touches `started` BEFORE `read` opens the FIFO, so ENXIO here can mean
      # "reader not open yet", not "never reached op": wait (bounded) for the reader.
      release_by = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      begin
        File.open(fifo, File::WRONLY | File::NONBLOCK) { |f| f.puts("go") }
      rescue Errno::ENXIO
        retry if Process.clock_gettime(Process::CLOCK_MONOTONIC) < release_by && (Thread.pass || true)
        Process.kill("KILL", pid)
      end
      _, status = Process.wait2(pid)
    end

    assert status.success?, "the first warm completes once op answers"
    assert_equal 1, op_calls.size, "one 1Password read for two warms"
    lines, ok = SoulSecrets.warm(SoulSecrets.manifest("avi", cfg(e)), env: e, wait: 0)
    assert ok
    assert_match(/fresh/, lines.join, "after the lock frees, the set is fresh and costs nothing")
    assert_equal 1, op_calls.size
  end
end
