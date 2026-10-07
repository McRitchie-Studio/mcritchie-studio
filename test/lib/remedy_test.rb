# frozen_string_literal: true

# [unit][control] Remedy, the one helper every printed remedy hint goes through.
#
# A hint is a command the reader pastes. It drifted two ways before this helper:
# it printed a BARE `bin/<script>` that runs only from a hub checkout (on a satellite
# or gem desk it is `No such file or directory`), and it could name a script that no
# longer exists. These tests pin both shut by construction:
#
#   * every hint renders from the real command name, as an absolute executable;
#   * a hint for a script that is not on disk raises UnknownScript, and because the
#     scripts build their hints as constants at load, that failure lands in every
#     test that loads the script, not in a reader's paste.
#
# The assertions ask the DISK (File.executable?) rather than the wording: an
# absolute path CONTAINS the bare form, so a substring match passes the very defect
# it means to catch (measured on PR #1341).
#
#   ruby -Itest test/lib/remedy_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../../bin/lib/remedy"

class RemedyTest < Minitest::Test
  BIN = File.expand_path("../../bin", __dir__)

  # The hub tools whose remedies the scripts print. Each lives in mcritchie-studio/bin
  # alone, so a bare form of any of them fails off a hub desk.
  HUB_SCRIPTS = %w[submit fast-check dor-check task session-preflight agent-worktree
                   pr-review reviewer-select gh-auth-refresh gh-token release conductor
                   control-check qa-intake submit-wait].freeze

  # --- [unit] the helper renders each hint from the real command name --------

  def test_each_hint_renders_from_the_real_command_name_as_an_absolute_executable
    HUB_SCRIPTS.each do |script|
      line = Remedy.command(script, BIN, "some-task", "--flag")
      first = line.split(" ").first

      assert_equal "#{File.join(BIN, script)} some-task --flag", line
      assert_equal File.expand_path(first), first, "#{script}: the hint must be absolute, got #{line}"
      assert File.executable?(first), "#{script}: the hint must name a real executable, got #{line}"
    end
  end

  def test_the_known_scripts_are_read_from_the_disk
    scripts = Remedy.scripts

    HUB_SCRIPTS.each { |script| assert_includes scripts, script }
    refute_includes scripts, "lib", "a directory is not a script"
    assert_equal Remedy::HOME_BIN, BIN
  end

  def test_blank_args_are_dropped_so_a_pasted_command_has_no_double_space
    line = Remedy.command("task", BIN, "move", "some-task", "", nil, "building")

    assert_equal "#{File.join(BIN, 'task')} move some-task building", line
  end

  def test_gh_auth_refresh_is_the_eval_line_with_an_absolute_script
    assert_equal %(eval "$(#{File.join(BIN, 'gh-auth-refresh')} --export)"), Remedy.gh_auth_refresh(BIN)
  end

  def test_token_export_names_the_variable_the_read_consumes
    assert_equal %(export GITHUB_TOKEN="$(#{File.join(BIN, 'gh-token')})"), Remedy.token_export("GITHUB_TOKEN", BIN)
    ["", "  ", nil].each do |blank|
      assert_raises(ArgumentError, "a blank env name must refuse, not default") { Remedy.token_export(blank, BIN) }
    end
  end

  def test_resolve_bin_prefers_the_first_directory_that_actually_carries_the_script
    Dir.mktmpdir do |root|
      desk = File.join(root, "desk", "bin")
      hub = File.join(root, "hub", "bin")
      FileUtils.mkdir_p([desk, hub])
      executable(File.join(hub, "submit"))

      assert_equal File.join(hub, "submit"), Remedy.resolve_bin("submit", [desk, hub])

      executable(File.join(desk, "submit"))
      assert_equal File.join(desk, "submit"), Remedy.resolve_bin("submit", [desk, hub])
    end
  end

  def test_a_non_executable_file_does_not_win_the_resolution
    Dir.mktmpdir do |root|
      desk = File.join(root, "desk", "bin")
      hub = File.join(root, "hub", "bin")
      FileUtils.mkdir_p([desk, hub])
      File.write(File.join(desk, "submit"), "not executable\n")
      executable(File.join(hub, "submit"))

      assert_equal File.join(hub, "submit"), Remedy.resolve_bin("submit", [desk, hub])
    end
  end

  def test_resolve_bin_still_names_an_absolute_path_when_no_candidate_carries_it
    line = Remedy.resolve_bin("submit", ["/nonexistent/a/bin", "/nonexistent/b/bin"])

    assert_equal "/nonexistent/b/bin/submit", line
  end

  # --- [control] the old drift is now impossible -----------------------------

  # DRIFT 1, the bare form. FastLane.resolve_bin returned `script.to_s` when it was
  # handed no directory, so `remedy_command("submit", nil, slug)` printed the bare
  # `submit <slug>`. The helper has no bare arm: no directory means its own bin.
  def test_control_no_directory_still_renders_an_absolute_hint
    [nil, [], "", ["  "]].each do |dirs|
      line = Remedy.command("submit", dirs, "some-task")

      assert_equal "#{File.join(BIN, 'submit')} some-task", line, "dirs=#{dirs.inspect} printed #{line}"
    end
    assert_equal File.join(BIN, "submit"), Remedy.resolve_bin("submit")
  end

  # DRIFT 2, a hint for a script that is not there. A rename or a retirement used to
  # leave the old name printing happily. Now it cannot be rendered at all.
  def test_control_a_hint_for_a_script_that_is_not_on_disk_raises
    ["full-suite-check", "no-such-script", "", nil, "bin/task", "../bin/task", "lib"].each do |name|
      assert_raises(Remedy::UnknownScript, "#{name.inspect} must not render") do
        Remedy.command(name, BIN, "some-task")
      end
    end
  end

  # DRIFT 2, end to end. A script builds its hint as a load-time constant; retire the
  # script it names and the speaker no longer LOADS. Built in a throwaway tree with
  # the real remedy.rb, so the rename is real and nothing in the checkout moves.
  def test_control_retiring_a_script_breaks_every_speaker_at_load
    Dir.mktmpdir do |root|
      bin = File.join(root, "bin")
      FileUtils.mkdir_p(File.join(bin, "lib"))
      FileUtils.cp(File.join(BIN, "lib", "remedy.rb"), File.join(bin, "lib", "remedy.rb"))
      executable(File.join(bin, "task"))
      speaker = File.join(bin, "speaker")
      File.write(speaker, <<~RUBY)
        require_relative "lib/remedy"
        CMD = Remedy.command(ARGV.fetch(0), __dir__, "show", "some-task")
        puts CMD
      RUBY

      out, _err, ok = run_ruby(speaker, "task")
      assert ok, "a hint for a script that exists must load"
      assert_equal "#{File.realpath(bin)}/task show some-task", out.strip

      _out, err, ok = run_ruby(speaker, "fast-check")
      refute ok, "a hint for a script this tree does not carry must fail at load"
      assert_includes err, "Remedy::UnknownScript"
      assert_includes err, "no bin/fast-check"
    end
  end

  private

  def executable(path)
    File.write(path, "#!/bin/sh\n")
    FileUtils.chmod(0o755, path)
  end

  def run_ruby(script, *args)
    out, err, status = Open3.capture3(RbConfig.ruby, script, *args)
    [out, err, status.success?]
  end
end
