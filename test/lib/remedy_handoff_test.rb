# frozen_string_literal: true

# [unit] Remedy.handoff and Remedy.resolve_bin: the line `bin/task begin` prints
# last, and which copy of a script a hint names. The end-to-end wiring (that
# `bin/task begin` prints this line) is pinned in test/lib/task_begin_test.rb.
#
#   ruby -Itest test/lib/remedy_handoff_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/remedy"

class RemedyHandoffTest < Minitest::Test
  # --- Remedy.handoff ---------------------------------------------------------
  # THE HINT IS A CLAIM ABOUT WHERE A SCRIPT LIVES, and nothing checked it against
  # the filesystem until this task. These assertions are keyed on the disk, not on
  # the wording: the command the tool prints must RESOLVE to an existing executable
  # and must name the desk to run it from. The end-to-end wiring — that `bin/task
  # begin` actually prints this — is pinned in test/lib/task_begin_test.rb, because a
  # correct helper the script never calls fixes nothing.

  # The bin/ of the checkout these tests ship in — the real hub bin dir, so the
  # fallback arm is asserted against the real bin/submit rather than a fixture.
  HUB_BIN = File.expand_path("../../bin", __dir__)

  # A bare `bin/submit`, and ONLY a bare one: the lookbehind exempts any path form
  # (/Users/…/bin/submit, ./bin/submit). Same shape as the docs guard in
  # test/docs/fast_lane_hub_path_docs_test.rb.
  BARE_SHIP = %r{(?<![\w/.-])bin/submit(?![\w-])}

  # [cd-target, submit, slug] parsed out of `cd <desk> && <submit> <slug>`.
  def parse_handoff(command)
    cd, run = command.split(" && ", 2)
    refute_nil run, "the hint must join a cd and the submit invocation: #{command.inspect}"
    submit, slug = run.split(" ", 2)
    [cd.to_s.sub(/\Acd /, ""), submit, slug.to_s.strip]
  end

  def test_handoff_command_names_an_executable_submit
    Dir.mktmpdir("desk-without-submit") do |desk|
      _cd, submit, slug = parse_handoff(Remedy.handoff("fix-nav-bug", desk, HUB_BIN))

      assert_equal "fix-nav-bug", slug
      assert_equal submit, File.expand_path(submit),
                   "the hint must name an ABSOLUTE submit path — a relative one resolves " \
                   "only from whichever desk the reader happens to be standing in"
      assert File.executable?(submit),
             "begin would print #{submit}, which is not an executable file — the hint " \
             "names a script that does not exist"
    end
  end

  # The defect itself. A satellite desk carries no bin/submit, so the bare form the
  # hint used to print died as `nohup: bin/submit: No such file or directory`.
  def test_handoff_command_is_never_bare
    Dir.mktmpdir("desk-without-submit") do |desk|
      command = Remedy.handoff("fix-nav-bug", desk, HUB_BIN)
      refute_match BARE_SHIP, command,
                   "the hint printed a bare bin/submit, which resolves only from a hub desk"
    end
    # Non-vacuity: the pattern must really bite the form this test forbids.
    assert_match BARE_SHIP, "hand off with: bin/submit fix-nav-bug",
                 "BARE_SHIP does not match the bare form, so the assertion above proves nothing"
  end

  # The cwd half. bin/submit roots at the cwd's git toplevel and, off a foreign root,
  # RE-ROOTS at the task's desk loudly rather than refusing (bin/submit's `--- rooting ---`
  # block); it dies only when no desk resolves. Naming the desk is still half the
  # instruction: the re-root is a correction the reader must notice, and the cert WRITERS
  # run by hand next (bin/fast-check, bin/full-suite-check) DO refuse a foreign root —
  # so a hint that names the script alone trades one failure for its mirror image.
  def test_handoff_command_stands_in_the_desk
    Dir.mktmpdir("desk-without-submit") do |desk|
      cd, = parse_handoff(Remedy.handoff("fix-nav-bug", desk, HUB_BIN))
      assert_equal desk, cd, "the hint must cd to the task's desk before running submit"
    end
  end

  # A hub desk ships its own bin/, and it is fresh off `accepted` while a primary
  # routinely lags it — so the desk's own script wins when there is one.
  def test_handoff_command_prefers_the_desks_own_submit
    Dir.mktmpdir("desk-with-submit") do |desk|
      desk_submit = File.join(desk, "bin", "submit")
      FileUtils.mkdir_p(File.dirname(desk_submit))
      File.write(desk_submit, "#!/bin/sh\n")
      FileUtils.chmod("+x", desk_submit)

      _cd, submit, = parse_handoff(Remedy.handoff("fix-nav-bug", desk, HUB_BIN))
      assert_equal desk_submit, submit, "a desk that carries bin/submit must be handed its own"
    end
  end

  # Resolution is by EXECUTABILITY, not mere presence: a non-executable file at that
  # path cannot be run, so it must not be printed as if it could.
  def test_handoff_command_ignores_a_non_executable_desk_submit
    Dir.mktmpdir("desk-with-dud-submit") do |desk|
      dud = File.join(desk, "bin", "submit")
      FileUtils.mkdir_p(File.dirname(dud))
      File.write(dud, "not a program")
      FileUtils.chmod(0o644, dud)

      _cd, submit, = parse_handoff(Remedy.handoff("fix-nav-bug", desk, HUB_BIN))
      refute_equal dud, submit, "a non-executable desk submit must not be printed"
      assert File.executable?(submit), "the fallback must be a runnable script"
    end
  end

  # A remedy printed by the FIXED-PATH TOOLING names the stable link, not the SHA dir
  # the next ship may prune; a moved link or an ordinary dir is left alone.
  def test_resolve_bin_names_the_stable_tooling_link
    Dir.mktmpdir do |root|
      state = File.join(root, "state")
      sha_bin = File.join(state, "tooling", "abc123", "bin")
      FileUtils.mkdir_p(sha_bin)
      File.write(File.join(state, "tooling", "abc123", ".complete"), "abc123\n")
      script = File.join(sha_bin, "ship")
      File.write(script, "#!/bin/sh\n")
      File.chmod(0o755, script)
      File.symlink("tooling/abc123/bin", File.join(state, "bin"))

      assert_equal File.join(state, "bin", "ship"), Remedy.resolve_bin("ship", sha_bin)

      File.unlink(File.join(state, "bin"))
      other = File.join(state, "tooling", "def456", "bin")
      FileUtils.mkdir_p(other)
      File.symlink("tooling/def456/bin", File.join(state, "bin"))
      assert_equal script, Remedy.resolve_bin("ship", sha_bin), "a link that moved on is not this tree's name"
    end
  end
end
