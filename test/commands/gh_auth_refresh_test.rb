# frozen_string_literal: true

# [integration] bin/gh-auth-refresh — the recovery an agent runs when it is ALREADY
# blocked.
#
# WHY THIS FILE EXERCISES THE REMEDY INSTEAD OF ASSERTING ITS TEXT. The thing this
# command replaces was advice — a string printed by the CI gates and by
# credentials.md — and it was WRONG for over a week while a test asserting that the
# string appeared in the file would have stayed green the whole time. Advice is a
# failure-path artifact: it only ever runs when something is broken, so it has to be
# EXECUTED in the broken configuration or it is not tested at all. Every case below
# therefore runs the real command against a `gh` stub that reproduces gh 2.92.0's
# actual refusal, verbatim, and asserts what ends up in the keyring.
#
# NOTHING HERE TOUCHES THE REAL KEYRING. `gh auth login` on macOS writes the login
# KEYCHAIN, which GH_CONFIG_DIR does NOT isolate (verified while building this: a
# fresh empty GH_CONFIG_DIR still served the operator's live token). An unseamed
# test would overwrite a live credential, so `gh` and the broker are both stubbed.
#
#   ruby -Itest test/commands/gh_auth_refresh_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class GhAuthRefreshTest < Minitest::Test
  BIN = File.expand_path("../../bin/gh-auth-refresh", __dir__)
  # Anything shaped like a GitHub credential. The character class INCLUDES `.` and
  # `-` on purpose: a modern installation token is a dotted JWT
  # (`ghs_<base64>.<base64>.<sig>`), so a pattern of `[A-Za-z0-9_]+` stops at the
  # first dot and silently passes the rest through. That exact gap turned a
  # redaction into a leak while this task was being built.
  TOKEN_SHAPED = /gh[psou]_[A-Za-z0-9_.-]{8,}|github_pat_[A-Za-z0-9_.-]{8,}/
  DEPLOYER_ITEM = "github.mcritchie-deployer"
  AGENT_ITEM = "github.mcritchie-agent"

  # A token with the real modern SHAPE, used to prove the guards above bite on the
  # form that actually ships rather than only on a tidy stub.
  DOTTED_TOKEN = "ghs_16C7e42F292c6912E7710c838347Ae178B4a.eyJhbGciOiJIUzI1NiJ9.q-3sT_signature"

  # gh 2.92.0's REAL words when it refuses to store a credential because GH_TOKEN is
  # set. Copied from a live run, not invented — a stub that refuses with different
  # text would let a broken fix pass.
  GH_REFUSAL = [
    "The value of the GH_TOKEN environment variable is being used for authentication.",
    "To have GitHub CLI store credentials instead, first clear the value from the environment."
  ].freeze

  def setup
    @dir = Dir.mktmpdir
    @keyring = File.join(@dir, "keyring")
    @broker_log = File.join(@dir, "broker.log")

    # A `gh` that behaves like the real one on the two calls this command makes.
    gh = File.join(@dir, "gh-stub")
    File.write(gh, <<~SH)
      #!/bin/sh
      if [ "$1" = "auth" ] && [ "$2" = "login" ]; then
        if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
          echo "#{GH_REFUSAL[0]}" >&2
          echo "#{GH_REFUSAL[1]}" >&2
          exit 1
        fi
        cat > "$STUB_KEYRING"
        exit 0
      fi
      if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
        if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; exit 0; fi
        [ -f "$STUB_KEYRING" ] || exit 1
        cat "$STUB_KEYRING"
        exit 0
      fi
      exit 2
    SH
    File.chmod(0o755, gh)

    # A broker that records the identity it was asked for and returns a token whose
    # VALUE names that identity — so the keyring's contents prove which App landed,
    # rather than a flag merely having been passed along.
    broker = File.join(@dir, "broker-stub")
    File.write(broker, <<~SH)
      #!/bin/sh
      echo "$*" >> "$STUB_BROKER_LOG"
      ident=agent
      while [ $# -gt 0 ]; do
        if [ "$1" = "--identity" ]; then ident="$2"; fi
        shift
      done
      echo "ghs_stub_${ident}"
    SH
    File.chmod(0o755, broker)

    @env = {
      "GH_AUTH_REFRESH_GH_BIN" => gh,
      "GH_AUTH_REFRESH_TOKEN_BIN" => broker,
      "STUB_KEYRING" => @keyring,
      "STUB_BROKER_LOG" => @broker_log,
      "GH_TOKEN" => nil,
      "GITHUB_TOKEN" => nil,
      "GH_APP_ITEM" => nil
    }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_refresh(env = {}, *args)
    Open3.capture3(@env.merge(env), BIN, *args)
  end

  def keyring = File.exist?(@keyring) ? File.read(@keyring).strip : nil
  def broker_log = File.exist?(@broker_log) ? File.read(@broker_log) : ""

  # === DEFECT 1 ==============================================================
  # The property, stated plainly: with GH_TOKEN set — the configuration the docs
  # themselves tell agents to create — the recovery must CHANGE THE AUTH STATE, or
  # fail loudly. The old advice did neither: gh refused, nothing moved, and the next
  # read failed identically.
  def test_with_gh_token_set_the_recovery_actually_changes_the_auth_state
    _out, err, status = run_refresh({ "GH_TOKEN" => "ghs_STALEambient" })

    assert_equal "ghs_stub_agent", keyring,
                 "the keyring must hold the FRESH token — a refusal here is the bug this fixes"
    refute_equal 0, status.exitstatus,
                 "GH_TOKEN still outranks the keyring, so this session is NOT fixed: say so loudly"
    assert_match(/GH_TOKEN/, err)
    assert_match(/--export/, err, "the loud failure must name the command that actually fixes it")
  end

  # The stub is only honest if it really refuses the way gh does. Prove the trap is
  # armed: hand the same stub an unscrubbed environment and it must refuse.
  def test_the_gh_stub_reproduces_the_real_refusal
    out, err, status = Open3.capture3(
      { "STUB_KEYRING" => @keyring, "GH_TOKEN" => "ghs_ambient" },
      File.join(@dir, "gh-stub"), "auth", "login", "-h", "github.com", "--with-token",
      stdin_data: "ghs_whatever"
    )

    refute status.success?, "the control: gh refuses while GH_TOKEN is set"
    assert_includes err, GH_REFUSAL[0]
    assert_nil keyring, "and it stores nothing"
    assert_empty out
  end

  # --export is the branch that genuinely repairs a running shell.
  def test_export_emits_an_eval_line_and_succeeds
    out, _err, status = run_refresh({ "GH_TOKEN" => "ghs_STALEambient" }, "--export")

    assert_equal 0, status.exitstatus
    assert_equal "export GH_TOKEN='ghs_stub_agent'", out.strip,
                 "stdout is the eval contract and carries nothing else"
    assert_equal "ghs_stub_agent", keyring, "and the keyring is refreshed in the same pass"
  end

  def test_a_clean_session_refreshes_and_exits_zero
    _out, _err, status = run_refresh

    assert_equal 0, status.exitstatus
    assert_equal "ghs_stub_agent", keyring
  end

  # === DEFECT 2 ==============================================================
  # A SHIP-lane recovery must install the DEPLOYER App. Installing `agent` hands the
  # ship lane `pull_requests: write`, which the deployer is denied on purpose — the
  # boundary defeating itself through its own error message.
  def test_a_ship_lane_recovery_installs_the_deployer_identity
    _out, _err, status = run_refresh({ "GH_APP_ITEM" => DEPLOYER_ITEM })

    assert_equal 0, status.exitstatus
    assert_equal "ghs_stub_deployer", keyring,
                 "the ship lane must NOT be handed the PR-writing App"
    refute_equal "ghs_stub_agent", keyring
    assert_includes broker_log, "--identity deployer"
  end

  def test_a_ship_lane_export_also_carries_the_deployer_identity
    out, _err, status = run_refresh({ "GH_APP_ITEM" => DEPLOYER_ITEM, "GH_TOKEN" => "ghs_stale" }, "--export")

    assert_equal 0, status.exitstatus
    assert_equal "export GH_TOKEN='ghs_stub_deployer'", out.strip
  end

  def test_an_explicit_identity_outranks_a_stale_lane_export
    _out, _err, _status = run_refresh({ "GH_APP_ITEM" => DEPLOYER_ITEM }, "--identity", "agent")

    assert_equal "ghs_stub_agent", keyring, "a caller that names its lane wins"
  end

  # A typo'd lane must abort, not fall back to the most privileged identity.
  def test_an_unknown_lane_aborts_without_installing_anything
    _out, err, status = run_refresh({ "GH_APP_ITEM" => "github.mcritchie-typo" })

    refute_equal 0, status.exitstatus
    assert_nil keyring, "nothing installed — silently choosing `agent` here IS the bug"
    assert_match(/github\.mcritchie-typo/, err)
  end

  # A lane named with the value MISSING is the same unreadable instruction as a typo'd
  # item, arriving through a more ordinary door: `--identity "$VAR"` with VAR unset.
  # Falling through to the default here hands the caller the App holding
  # `pull_requests: write` — the one outcome this command exists to prevent.
  def test_an_empty_identity_value_aborts_without_installing_anything
    [["--identity"], ["--identity", ""], ["--identity", "   "]].each do |argv|
      _out, err, status = run_refresh({}, *argv)

      refute_equal 0, status.exitstatus, "#{argv.inspect} must abort, not resolve to the default"
      assert_nil keyring, "#{argv.inspect} must install nothing"
      assert_match(/empty/i, err, "#{argv.inspect} must name the ARGUMENT as the fault")
    end
  end

  def test_an_empty_identity_aborts_even_when_the_environment_would_answer
    [{ "GH_APP_ITEM" => DEPLOYER_ITEM }, { "GH_APP_ITEM" => AGENT_ITEM }].each do |env|
      out, _err, status = run_refresh(env, "--identity")

      refute_equal 0, status.exitstatus,
                   "a caller that named its lane and lost the value must not inherit the env's"
      assert_nil keyring
      assert_equal 0, out.bytesize, "an error path emits nothing on stdout — that is the eval channel"
    end
  end

  # === THE REMEDY ROUND-TRIP =================================================
  # THE PROPERTY, and it is the one this whole command is for: EVERY remedy this file
  # prints must round-trip. Run it verbatim, in the lane that printed it, and the SAME
  # identity must end up installed.
  #
  # The defect it exists to catch: the exit-3 remedy forwarded --force but not
  # --identity. A ship session ran `--identity deployer`, got exit 3 with the keyring
  # CORRECTLY on deployer, followed the printed line, and ended with keyring = agent and
  # GH_TOKEN = agent — the very lane crossing named as defect 3 in this file's own
  # header, reproduced inside its replacement. Advice only ever runs when someone is
  # already stuck, so the only honest test of it is to EXECUTE it; asserting that the
  # line contains "--identity" would pass on a line that names the wrong one.
  #
  # It is written as a sweep over lanes rather than one case so the NEXT remedy added to
  # this file inherits the guard instead of needing its own.
  ROOT = File.expand_path("../..", __dir__)

  # Every runnable remedy in the command's report, found the way a copying operator
  # finds one: a line that IS an invocation of this command.
  def printed_remedies(stderr)
    stderr.lines.filter_map do |line|
      text = line.strip.sub(/\Agh-auth-refresh:\s*/, "")
      text if text.match?(%r{\A(?:eval\s+"\$\()?bin/gh-auth-refresh\b})
    end
  end

  # Run a remedy EXACTLY as printed, then report what this shell's GH_TOKEN became.
  def follow(env, remedy)
    out, _err, _status = Open3.capture3(
      @env.merge(env), "sh", "-c", %(#{remedy}; printf '%s' "${GH_TOKEN:-}"), chdir: ROOT
    )
    out
  end

  # lane env + args => the identity that lane resolves to.
  REMEDY_LANES = {
    "an explicit ship lane" => [{}, ["--identity", "deployer"], "deployer"],
    "a ship lane from the environment" => [{ "GH_APP_ITEM" => DEPLOYER_ITEM }, [], "deployer"],
    # THE HOSTILE CASE, and the reason the remedy must carry its identity rather than
    # trust the shell: an explicit lane whose ambient export says the OTHER App. A
    # remedy that relies on the environment surviving the copy-paste lands `agent` here.
    "an explicit lane contradicted by the export" => [{ "GH_APP_ITEM" => AGENT_ITEM }, ["--identity", "deployer"], "deployer"],
    "the default build lane" => [{}, [], "agent"]
  }.freeze

  def test_every_printed_remedy_installs_the_lane_that_printed_it
    REMEDY_LANES.each do |label, (env, args, expected)|
      lane_env = env.merge("GH_TOKEN" => "ghs_STALEambient")
      _out, err, status = run_refresh(lane_env, *args)

      assert_equal 3, status.exitstatus, "#{label}: expected the GH_TOKEN-shadowed exit"
      assert_equal "ghs_stub_#{expected}", keyring, "#{label}: the printing run itself must be correct"

      remedies = printed_remedies(err)
      refute_empty remedies, "#{label}: no runnable remedy was printed, so this guard proves nothing"

      remedies.each do |remedy|
        File.delete(@keyring) if File.exist?(@keyring)
        exported = follow(lane_env, remedy)

        assert_equal "ghs_stub_#{expected}", keyring,
                     "#{label}: following the printed remedy verbatim installed the WRONG identity " \
                     "in the keyring"
        next unless remedy.include?("--export")

        assert_equal "ghs_stub_#{expected}", exported,
                     "#{label}: the remedy repaired this shell with the WRONG identity"
        refute_equal "ghs_STALEambient", exported, "#{label}: the remedy left the stale token in place"
      end
    end
  end

  # SAYING WHICH IDENTITY LANDED WHERE, BY WHICH ROUTE, is this command's stated
  # deliverable, so a route label that can be wrong is a defect in the product. It was
  # derived from `ARGV.include?("--identity")` — the presence of a flag rather than the
  # resolution that actually happened — and reported "via --identity" for a GH_APP_ITEM
  # or default lane whenever the flag's value was lost.
  #
  # WHAT THIS CASE DOES AND DOES NOT PROVE, stated plainly rather than implied. It pins
  # that each of the three routes is reported as itself: a wrong MAPPING (swap two
  # branches) fails here, measured. It does NOT discriminate against the old
  # `ARGV.include?` spelling, because the only input on which the two expressions differ
  # — `--identity` with an empty value — now aborts upstream, so that spelling is
  # unreachable-wrong rather than wrong. The derived form is kept because it cannot
  # start lying again if the empty-value refusal is ever relaxed or a second
  # value-taking flag is added; that is correctness by construction, not by this test.
  def test_the_reported_lane_source_matches_the_route_actually_taken
    {
      "--identity" => [{ "GH_APP_ITEM" => AGENT_ITEM }, ["--identity", "deployer"]],
      "GH_APP_ITEM" => [{ "GH_APP_ITEM" => DEPLOYER_ITEM }, []],
      "default" => [{}, []]
    }.each do |expected, (env, args)|
      _out, err, = run_refresh(env, *args)

      assert_match(/via #{Regexp.escape(expected)}\b/, err, "the lane came from #{expected}")
    end
  end

  # The control for the extractor: if `printed_remedies` silently found nothing, every
  # assertion in the sweep above would be vacuous. Prove it finds the line that exists,
  # and that it does not mistake the command's ordinary report for a remedy.
  def test_the_remedy_extractor_finds_commands_and_only_commands
    _out, err, = run_refresh({ "GH_TOKEN" => "ghs_STALEambient" })
    found = printed_remedies(err)

    assert_equal 1, found.length, "exactly one runnable remedy is printed on the exit-3 path"
    assert_includes found.first, "bin/gh-auth-refresh"
    refute_empty err.lines.reject { |l| found.include?(l.strip) },
                 "the report also contains prose, which must NOT be mistaken for a command"
    assert_empty printed_remedies("gh-auth-refresh: identity agent (github.mcritchie-agent) via default\n"),
                 "a status line that merely names the command is not a remedy"
  end

  # === HYGIENE ===============================================================
  # Every path but the documented --export contract must be token-free. This command
  # is run by blocked agents whose output lands in transcripts and task records.
  def test_no_token_is_ever_printed_outside_the_export_contract
    out, err, _status = run_refresh({ "GH_TOKEN" => "ghs_STALEambient" })

    refute_match TOKEN_SHAPED, out, "stdout leaked a token"
    refute_match TOKEN_SHAPED, err, "stderr leaked a token"
  end

  def test_the_report_identifies_the_token_by_digest_only
    _out, err, _status = run_refresh

    assert_match(/sha256:[0-9a-f]{12}/, err, "the operator gets a comparable fingerprint")
    refute_match TOKEN_SHAPED, err
  end

  # The guard must hold for a token of the REAL shape, not just the tidy stub. A
  # dotted JWT is what GitHub actually issues, and it is what slipped past a
  # `[A-Za-z0-9_]+` redaction during this task.
  def test_a_realistically_shaped_token_never_reaches_stdout_or_stderr
    broker = File.join(@dir, "dotted-broker")
    File.write(broker, "#!/bin/sh\necho '#{DOTTED_TOKEN}'\n")
    File.chmod(0o755, broker)

    out, err, _status = run_refresh({ "GH_AUTH_REFRESH_TOKEN_BIN" => broker, "GH_TOKEN" => DOTTED_TOKEN })

    assert_equal DOTTED_TOKEN, keyring, "the dotted token still installs correctly"
    refute_match TOKEN_SHAPED, out
    refute_match TOKEN_SHAPED, err
    refute_includes err, DOTTED_TOKEN.split(".").last, "not even the signature segment may appear"
  end

  # The control for the guard itself: TOKEN_SHAPED must actually match a real token,
  # or every refute_match above is vacuously true.
  def test_the_leak_guard_matches_a_real_token_shape
    assert_match TOKEN_SHAPED, DOTTED_TOKEN, "a guard that matches nothing proves nothing"
    assert_match TOKEN_SHAPED, "ghs_stub_agent"
    refute_match TOKEN_SHAPED, "sha256:bcdf2f7e20ce", "a digest is not a token"
  end

  def test_a_broker_that_cannot_mint_fails_loudly_and_installs_nothing
    dead = File.join(@dir, "dead-broker")
    File.write(dead, "#!/bin/sh\necho 'op is not signed in' >&2\nexit 1\n")
    File.chmod(0o755, dead)

    _out, err, status = run_refresh({ "GH_AUTH_REFRESH_TOKEN_BIN" => dead })

    refute_equal 0, status.exitstatus
    assert_nil keyring
    assert_match(/op is not signed in/, err, "the broker's actionable reason survives")
  end
end
