# frozen_string_literal: true

# [integration] bin/chrome-profiles end to end — the real script, spawned as a real
# process, against a fixture `Local State` it is allowed to destroy.
#
# WHAT MAKES THIS WORTH SPAWNING. The unit tier next door proves the resolver's
# decision table. It cannot prove the two things that actually protect the
# operator's machine, because both live in the script rather than the library:
#
#   1. THE ARGUMENT GUARD RUNS BEFORE THE DISPATCHER. `apply` quits the operator's
#      browser and rewrites Chrome's own state file; `pin-dock` rewrites
#      com.apple.dock. None of that is undone by `git checkout`. A static index of
#      `CliArgGuard.guard!` in test/lib/bin_help_flag_class_test.rb cannot tell a
#      guard that is CALLED from one merely DEFINED — measured at
#      finding-e429a953ff23, where an entire manifest passed against a fully
#      unguarded script.
#   2. A REFUSING PLAN WRITES NOTHING. `Writer.apply!` raises, but the script is
#      what decides whether that raise happens before or after the browser is quit.
#
# THE VERDICT IS A RECEIPT, not an exit code. "It printed usage" is not evidence
# that it did not also act. Every probe below is paired with a CONTROL that drives
# a real write through the same observation — the fixture's bytes, and whether a
# `.backup-*` file appeared beside it. Without the control, "the file is unchanged"
# and "the test is watching the wrong file" are the same observation.
#
# NOTHING HERE CAN REACH THE OPERATOR'S CHROME. Every invocation passes `--state`
# pointing into a tmp dir, and the script treats any path that is not the live
# `Local State` as OFFLINE: no quit, no relaunch, no verify. That branch is
# asserted below rather than assumed, because it is the whole reason this tier can
# run the real `apply` at all.
#
#   ruby -Itest test/commands/chrome_profiles_test.rb

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

class ChromeProfilesCommandTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "chrome-profiles")

  def setup
    @dir = Dir.mktmpdir("chrome-profiles-cmd")
    @state = File.join(@dir, "Local State")
    File.write(@state, JSON.generate(state_doc))
    @roster = File.join(@dir, "roster.yml")
    File.write(@roster, <<~YAML)
      profiles:
        - account: b@studio.test
          label: '🐊 turf'
        - account: a@studio.test
          label: '🪎 studio'
    YAML
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def state_doc(extra_profiles: {})
    cache = {
      "Default" => { "user_name" => "a@studio.test", "name" => "stale", "gaia_given_name" => "Alex" },
      "Profile 1" => { "user_name" => "b@studio.test", "name" => "stale", "gaia_given_name" => "Alex" }
    }.merge(extra_profiles)
    { "profile" => { "info_cache" => cache, "profiles_order" => [ "Default", "Profile 1" ] } }
  end

  def run_cli(*args)
    Open3.capture3(SCRIPT, *args, chdir: ROOT)
  end

  # The two receipts. `backups` is the second one because a write that is rolled
  # back still leaves its backup behind, so bytes alone could under-report.
  def bytes = File.read(@state)
  def backups = Dir.glob("#{@state}.backup-*")

  # ---------------------------------------------------------------------------
  # The guard, proven by receipt
  # ---------------------------------------------------------------------------

  def test_help_on_apply_prints_usage_and_writes_nothing
    before = bytes

    out, err, status = run_cli("apply", "--config", @roster, "--state", @state, "--help")

    refute_equal 0, status.exitstatus, "help exited 0, and this script's 0 is a verdict"
    assert_match(/NOT RUN — Chrome was NOT quit/, out + err)
    assert_equal before, bytes, "`apply --help` REWROTE Chrome's state file"
    assert_empty backups, "`apply --help` took a backup, so it began the write"
  end

  def test_an_unrecognised_flag_on_apply_refuses_and_writes_nothing
    before = bytes

    _, err, status = run_cli("apply", "--config", @roster, "--state", @state, "--dry-run")

    refute_equal 0, status.exitstatus
    assert_match(/--dry-run/, err)
    assert_equal before, bytes
    assert_empty backups
  end

  # THE CONTROL for both probes above. Without it, a script that cannot write at
  # all — a typo in the path, a chdir into the wrong tree — passes them exactly
  # the way a guarded one does.
  def test_the_control_apply_really_does_write_through_the_same_receipts
    before = bytes

    out, err, status = run_cli("apply", "--config", @roster, "--state", @state)

    assert_equal 0, status.exitstatus, "the control failed, so the probes above prove nothing:\n#{err}"
    refute_equal before, bytes, "the control did not write — the receipts watch the wrong file"
    assert_equal 1, backups.length, "the control took no backup"

    after = JSON.parse(bytes)
    assert_equal [ "Profile 1", "Default" ], after["profile"]["profiles_order"]
    assert_equal "🐊 turf", after["profile"]["info_cache"]["Profile 1"]["name"]
    assert_match(/wrote:/, out)
  end

  # ---------------------------------------------------------------------------
  # Offline is what lets this tier exist
  # ---------------------------------------------------------------------------

  # If this ever goes red, every other test in this file becomes capable of
  # quitting the operator's browser mid-suite.
  def test_a_state_that_is_not_the_live_one_never_touches_the_browser
    out, _, status = run_cli("status", "--config", @roster, "--state", @state)

    assert_equal 0, status.exitstatus
    assert_match(/chrome:\s+\(offline/, out)
    refute_match(/quitting Chrome/, out)
  end

  def test_apply_on_a_fixture_neither_quits_nor_relaunches
    out, _, = run_cli("apply", "--config", @roster, "--state", @state)

    refute_match(/quitting Chrome/, out)
    refute_match(/relaunching via/, out)
    assert_match(/=== verify \(re-read from disk\) ===/, out, "the write was never read back")
  end

  # ---------------------------------------------------------------------------
  # Refusals reach the exit code, not just the transcript
  # ---------------------------------------------------------------------------

  # An SOP step gates on this exit code, so a refusal that printed loudly and
  # exited 0 would be read by the next step as "the roster is clean".
  def test_a_profile_missing_from_the_roster_refuses_and_exits_nonzero
    File.write(@state, JSON.generate(state_doc(extra_profiles: {
      "Profile 14" => { "user_name" => "surprise@studio.test", "name" => "x", "gaia_given_name" => "Team" }
    })))
    before = bytes

    out, _, status = run_cli("status", "--config", @roster, "--state", @state)

    assert_equal 1, status.exitstatus
    assert_match(/REFUSALS/, out)
    assert_match(/Profile 14 \(surprise@studio\.test\)/, out)
    assert_equal before, bytes, "`status` is read-only and it wrote"
  end

  def test_apply_refuses_the_same_case_before_writing_anything
    File.write(@state, JSON.generate(state_doc(extra_profiles: {
      "Profile 14" => { "user_name" => "surprise@studio.test", "name" => "x", "gaia_given_name" => "Team" }
    })))
    before = bytes

    _, err, status = run_cli("apply", "--config", @roster, "--state", @state)

    assert_equal 1, status.exitstatus
    assert_match(/refusing to write/, err)
    assert_equal before, bytes
    assert_empty backups, "a refusing apply still took a backup, so it had begun the write"
  end

  # A roster account nobody has signed into yet is the NORMAL state mid-rebuild.
  # It must report and keep going, or the roster is useless for the one job it
  # exists to do.
  def test_an_account_not_yet_signed_into_reports_but_still_exits_zero
    File.write(@roster, <<~YAML)
      profiles:
        - account: a@studio.test
          label: '🪎 studio'
        - account: b@studio.test
          label: '🐊 turf'
        - account: notyet@studio.test
          label: '📐 industries'
    YAML

    out, _, status = run_cli("status", "--config", @roster, "--state", @state)

    assert_equal 0, status.exitstatus
    assert_match(/NOT SIGNED IN on this Mac \(1\)/, out)
    assert_match(/notyet@studio\.test/, out)
  end

  # ---------------------------------------------------------------------------
  # adopt round-trips, which is what a fresh Mac actually needs
  # ---------------------------------------------------------------------------

  # The rebuild path: adopt what a machine already has, paste it into the roster,
  # and the roster must then resolve against that same machine with no refusals.
  def test_adopt_emits_a_roster_that_resolves_against_the_machine_it_came_from
    out, _, status = run_cli("adopt", "--state", @state)

    assert_equal 0, status.exitstatus
    adopted = File.join(@dir, "adopted.yml")
    File.write(adopted, "profiles:\n#{out.lines.reject { |l| l.start_with?('#') }.join}")

    _, err, status = run_cli("status", "--config", adopted, "--state", @state)

    assert_equal 0, status.exitstatus, "an adopted roster did not resolve against its own machine:\n#{err}"
  end

  # ---------------------------------------------------------------------------
  # The vault is the default source, and it fails LOUDLY
  # ---------------------------------------------------------------------------

  # Driven through a STUB `op` on PATH rather than a bogus vault name, so it costs
  # no 1Password quota (the cap is account-wide and shared with every lane) and
  # behaves identically on CI, where `op` is not installed at all.
  # The payload goes through a FILE the stub cats, not through the script's own
  # text: an inlined `printf '%s' "..."` leaves \n as a literal backslash-n, and
  # the whole document arrives as one line. That cost a run.
  def stub_op(exit_status, stdout = "")
    bin = File.join(@dir, "stub-bin")
    FileUtils.mkdir_p(bin)
    payload = File.join(bin, "payload")
    File.write(payload, stdout)
    File.write(File.join(bin, "op"), "#!/bin/sh\ncat #{payload.inspect}\nexit #{exit_status}\n")
    File.chmod(0o755, File.join(bin, "op"))
    bin
  end

  def test_a_malformed_vault_document_names_its_source_instead_of_raising_psych
    env = { "PATH" => "#{stub_op(0, "profiles: - account: broken: yaml\n")}:#{ENV['PATH']}" }

    _, err, status = Open3.capture3(env, SCRIPT, "status", "--state", @state, chdir: ROOT)

    assert_equal 1, status.exitstatus
    assert_match(%r{op://.* is not valid YAML}, err)
    refute_match(/psych\.rb:\d+:in/, err, "Psych's backtrace reached the operator")
  end

  def test_an_unreachable_vault_aborts_cleanly_instead_of_printing_a_backtrace
    env = { "PATH" => "#{stub_op(1)}:#{ENV['PATH']}" }
    out, err, status = Open3.capture3(env, SCRIPT, "status", "--state", @state, chdir: ROOT)

    assert_equal 1, status.exitstatus
    assert_match(/Could not read the roster from 1Password/, err)
    refute_match(/chrome_profiles\.rb:\d+:in/, err, "a Ruby backtrace reached the operator")
    refute_match(/menu the roster produces/, out, "it fell back to something and produced a menu anyway")
  end

  # The control: the same code path with a vault that ANSWERS must resolve, or
  # the test above passes on a script that simply cannot read a roster at all.
  def test_the_control_a_vault_that_answers_resolves_without_any_config_flag
    doc = "profiles:\n" \
          "  - account: a@studio.test\n    label: '\u{1FA8E} studio'\n" \
          "  - account: b@studio.test\n    label: '\u{1F40A} turf'\n"
    env = { "PATH" => "#{stub_op(0, doc)}:#{ENV['PATH']}" }

    out, err, status = Open3.capture3(env, SCRIPT, "status", "--state", @state, chdir: ROOT)

    assert_equal 0, status.exitstatus, err
    assert_match(%r{roster:\s+op://}, out, "the source line must name the vault, not a path")
    assert_match(/menu the roster produces/, out)
  end

  # ---------------------------------------------------------------------------
  # Usage
  # ---------------------------------------------------------------------------

  def test_an_unknown_subcommand_prints_usage_and_exits_nonzero
    _, err, status = run_cli("reorder")

    refute_equal 0, status.exitstatus
    assert_match(/usage: bin\/chrome-profiles <command>/, err)
  end

  # Env-agnostic on purpose: whether a codepoint is PRESENT depends on a macOS-only
  # font, and CI runs on Ubuntu. What must hold everywhere is that the codepoint is
  # echoed in U+ form and that the answer is labelled as presence, not identity.
  def test_emoji_reports_each_codepoint_and_says_presence_is_not_identity
    out, _, = run_cli("emoji", "U+1FA8E")

    assert_match(/U\+1FA8E/, out)
    assert_match(/Presence is not identity/, out)
    assert_match(%r{docs/agents/agents/steffon/sops/chrome-profiles\.md}, out)
  end

  def test_emoji_without_an_argument_prints_its_synopsis
    _, err, status = run_cli("emoji")

    refute_equal 0, status.exitstatus
    assert_match(/bin\/chrome-profiles emoji <char-or-U\+XXXX>/, err)
  end
end
