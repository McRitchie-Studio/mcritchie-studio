# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# [unit] `bin/agent-worktree new` must be ATOMIC — a whole desk, or nothing.
#
# THE DEFECT. `new` is a SEQUENCE: cut the git worktree, allocate a port and a
# Redis DB into a stack env, write the context marker, provision the test DB. Any
# step can fail — a taken port, a full Redis band, an abort inside sh, a raise, a
# Ctrl-C — and every earlier step stayed on disk. What was left was a HALF-BUILT
# DESK: a checkout with a branch and no env, or an env holding a port and a Redis
# DB that nothing would ever release. Those leak silently, because a desk that
# looks real is never swept.
#
# Re-homed from PR #550, which sat open and unowned for six weeks. That branch is
# 1293 commits behind accepted and spans 16 files including bin/release.rb,
# bin/fast-check and the release gate models — concerns since superseded. Only the
# ATOMICITY intent is carried here, re-implemented against current code.
class DeskBringupAtomicityTest < ActiveSupport::TestCase
  def script
    @script ||= begin
      src = File.read(Rails.root.join("bin/agent-worktree")).sub(/^\s*main\b.*$/, "")
      host = Object.new
      host.instance_eval(src, "bin/agent-worktree")
      host
    end
  end

  def unwinder = script.singleton_class.const_get(:DeskUnwinder).new

  test "undos run in REVERSE, so each step unwinds into the state before it" do
    order = []
    u = unwinder
    u.on_success("first")  { order << :first }
    u.on_success("second") { order << :second }
    u.on_success("third")  { order << :third }

    capture_io { u.unwind! }

    assert_equal %i[third second first], order,
                 "undos ran forwards; a later step's undo can depend on an earlier one still " \
                 "being in place, so reverse order is the whole contract"
  end

  # A ROLLBACK THAT RAISES leaves exactly the mess it was called to prevent, AND
  # masks the original failure — which is the thing the operator needs to read.
  test "a failing undo does not stop the ones behind it" do
    reached = []
    u = unwinder
    u.on_success("innermost") { reached << :innermost }
    u.on_success("explodes")  { raise IOError, "disk gone" }
    u.on_success("outermost") { reached << :outermost }

    out, _err = capture_io { u.unwind! }

    assert_equal %i[outermost innermost], reached,
                 "one exploding undo aborted the rollback — the earlier steps stayed on disk"
    assert_match(/unwind FAILED for explodes/, out + _err,
                 "the failed undo must be REPORTED, not silently skipped")
  end

  test "committing discards the undos so a successful bringup keeps its desk" do
    ran = []
    u = unwinder
    u.on_success("would delete the desk") { ran << :deleted }

    u.commit!
    capture_io { u.unwind! }

    assert_empty ran, "a committed bringup still unwound — a successful `new` would delete itself"
  end

  # THE WIRING. Every behavioural test above drives DeskUnwinder directly, so all
  # of them would stay green if `new` never used it. This asserts the sequence is
  # actually wrapped, and that the three steps that leak register an undo.
  test "the new command wraps its bringup and registers an undo per step" do
    body = new_body

    assert_includes body, "DeskUnwinder.new", "`new` does not use the unwinder at all"
    assert_match(/unwinder\.on_success\("git worktree/, body,
                 "a failed bringup would leave the checkout and its branch behind")
    assert_match(/unwinder\.on_success\("stack env/, body,
                 "a failed bringup would leave an env holding a port and a Redis DB that nothing " \
                 "ever releases")
    assert_match(/unwinder\.unwind!/, body, "nothing ever triggers the rollback")
    assert_match(/unwinder\.commit!/, body,
                 "without a commit, a SUCCESSFUL new would unwind its own desk")
  end

  # NOT OURS TO DESTROY. Re-running `new` over an existing desk must repair it,
  # never delete it — the undos are registered only for what THIS run created.
  #
  # The git-worktree undo is now registered from INSIDE ensure_git_worktree (its
  # `on_cut` callback), so this is a BEHAVIOURAL test rather than a grep: the method
  # that knows whether it cut anything is the one that decides whether to register.
  test "an existing desk cuts nothing and registers no undo" do
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "repo", ".worktrees", "already-here")
      FileUtils.mkdir_p(dir)
      app = { "repo" => File.join(tmp, "repo"), "slug" => "repo" }
      script.define_singleton_method(:worktree_dir) { |_a, _t| dir }
      # sh would abort the whole process on a git failure; if it is reached at all the
      # early return is broken, and this makes that loud rather than mysterious.
      script.define_singleton_method(:sh) { |*_a, **_k| raise "ensure_git_worktree touched git on an existing desk" }

      registered = []
      returned = script.ensure_git_worktree(app, "already-here", "feat") { |d, b| registered << [d, b] }

      assert_equal dir, returned
      assert_empty registered,
                   "re-running new over an existing desk registered an undo that would DELETE " \
                   "someone else's live work on the next failure"
    end
  end

  # THE REGISTRATION WINDOW, pinned behaviourally. The undo used to be registered where
  # ensure_git_worktree RETURNS — after the `.env` copy. Everything between `git worktree
  # add` and that return was unguarded: an interrupt landing there left a checkout and a
  # branch on disk with no undo registered for them, the exact half-desk the unwinder
  # exists to prevent.
  #
  # This drives the REAL method against a REAL git repo, because the grep-based wiring
  # test above stays green when `on_cut` is never called — the block is still written in
  # the source, it just never fires, and the desk leaks in silence.
  test "the undo is registered the instant the worktree exists, before the .env tail" do
    Dir.mktmpdir do |tmp|
      repo = File.realpath(Dir.mktmpdir("primary", tmp))
      assert system("git -C #{repo} init -q -b main"), "git init"
      assert system("git -C #{repo} config user.email t@example.com")
      assert system("git -C #{repo} config user.name t")
      File.write(File.join(repo, "a"), "a\n")
      assert system("git -C #{repo} add -A && git -C #{repo} commit -q -m init")
      # A real remote so the bringup's `git fetch origin` succeeds; fetching a repo from
      # itself is enough to publish refs/remotes/origin/main for base_ref_for.
      assert system("git -C #{repo} remote add origin #{repo}")
      assert system("git -C #{repo} fetch -q origin")
      # The tail this test is about: a primary .env the bringup copies AFTER the cut.
      File.write(File.join(repo, ".env"), "SECRET=1\n")

      dir = File.join(repo, ".worktrees", "fresh-desk")
      app = { "repo" => repo, "slug" => "repo" }
      script.define_singleton_method(:worktree_dir) { |_a, _t| dir }

      seen = []
      script.ensure_git_worktree(app, "fresh-desk", "feat") do |cut_dir, cut_branch|
        seen << { dir: cut_dir, branch: cut_branch,
                  tail_done: File.exist?(File.join(cut_dir, ".env")) }
      end

      assert_equal 1, seen.size,
                   "the cut registered NO undo — a failure or an interrupt from here on leaves the " \
                   "checkout and its branch on disk with nothing to remove them"
      assert_equal dir, seen.first[:dir]
      assert_equal "feat/fresh-desk", seen.first[:branch],
                   "the undo needs the branch name too, or the branch outlives the desk and the " \
                   "next new for this slug fails on it"
      refute seen.first[:tail_done],
             "the undo was registered AFTER the .env copy — that copy is inside the unguarded " \
             "window this callback exists to close"
      assert Dir.exist?(dir), "precondition: the worktree really was cut"
    end
  end

  test "the stack env's pre-existing guard is still honoured" do
    body = new_body

    assert_match(/unless env_pre_existing/, body,
                 "a resume would register an undo for an env it did not create — deleting the " \
                 "port and Redis reservation of a desk someone else is using")
    assert_match(/unless marker_pre_existing/, body)
  end

  # --- the undo's VERDICT: a rollback must not overstate itself ----------------------
  #
  # THE DEFECT (Steffon, reviewing PR #1042). Every undo does its work through
  # `sh(..., allow_fail: true)` or FileUtils — neither raises on failure; `sh` returns
  # false and `rm_f` returns its argument. So the rescue never fired for the ORDINARY
  # failure, and "unwound: <label>" printed unconditionally afterwards: a locked
  # worktree reported a clean rollback while the desk sat on disk. An operator reads
  # "unwound" and stops looking, which is what makes an overstating rollback worse than
  # a loudly failing one.

  test "an undo that could not finish is reported as INCOMPLETE, not unwound" do
    u = unwinder
    u.on_success("locked worktree") { false }

    out, err = capture_io { u.unwind! }
    combined = out + err

    refute_match(/unwound: locked worktree/, combined,
                 "the rollback claimed success it did not achieve — the desk is still on disk")
    assert_match(/INCOMPLETE for locked worktree/, combined)
    assert_match(/by hand/, combined, "and it must tell the operator what is now theirs to do")
  end

  test "an undo that DID finish is still reported as unwound" do
    u = unwinder
    u.on_success("clean step") { true }

    out, err = capture_io { u.unwind! }

    assert_match(/unwound: clean step/, out + err)
    refute_match(/INCOMPLETE/, out + err, "a successful undo must not read as a leak")
  end

  # The two verdicts are DIFFERENT from an exception. A raise still reports FAILED and
  # still lets the steps behind it run; conflating the three would lose the distinction
  # between "it did not work", "it blew up", and "it worked".
  test "the three outcomes stay distinguishable" do
    u = unwinder
    u.on_success("worked")     { true }
    u.on_success("did not")    { false }
    u.on_success("blew up")    { raise IOError, "disk gone" }

    out, err = capture_io { u.unwind! }
    combined = out + err

    assert_match(/unwind FAILED for blew up/, combined)
    assert_match(/INCOMPLETE for did not/, combined)
    assert_match(/unwound: worked/, combined)
  end

  # The real undo, against a real git worktree. This is the block whose verdict the
  # printer now honours, so its verdict has to be TRUE.
  test "remove_worktree_and_branch reports honestly on a worktree git never registered" do
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "repo")
      FileUtils.mkdir_p(repo)
      assert system("git -C #{repo} init -q"), "git init"
      assert system("git -C #{repo} config user.email t@example.com")
      assert system("git -C #{repo} config user.name t")
      File.write(File.join(repo, "a"), "a\n")
      assert system("git -C #{repo} add -A && git -C #{repo} commit -q -m init")

      # A plain directory under .worktrees/ that git knows nothing about — exactly what
      # an interrupt between `worktree add` and its registration leaves behind. `git
      # worktree remove` errors on it, so a verdict read off that exit code would be
      # false while the rm_rf behind it actually did the job.
      # (git prints `fatal: … is not a working tree` to stderr here. That noise IS the
      # point: the exit code says failure, the directory says gone, and the verdict must
      # follow the directory.)
      orphan = File.join(repo, ".worktrees", "never-registered")
      FileUtils.mkdir_p(orphan)

      assert script.remove_worktree_and_branch(repo, orphan, nil),
             "the directory is gone, so the undo must report success"
      refute Dir.exist?(orphan)
    end
  end

  test "remove_worktree_and_branch reports failure when the desk survives" do
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, "repo")
      dir = File.join(repo, ".worktrees", "stuck")
      FileUtils.mkdir_p(dir)
      # Model the undo failing to remove it: git is a no-op and rm_rf cannot win.
      script.define_singleton_method(:sh) { |*_a, **_k| false }
      FileUtils.stub(:rm_rf, nil) do
        refute script.remove_worktree_and_branch(repo, dir, nil),
               "the desk is still on disk — reporting this as unwound is the defect"
      end
    end
  end

  # --- SIGTERM: the common agent path, and the one that was not covered --------------
  #
  # SIGINT raises Interrupt on its own; SIGTERM and SIGHUP kill the process outright
  # (rc=143) with no rescue and no unwind. An agent runs `new` under a harness Bash
  # timeout and the harness TERMs the process group, so this was the case that mattered
  # most and was covered least — while the header comment listed SIGTERM among the
  # failures handled.
  test "the new command traps TERM and HUP into the same unwind every other failure takes" do
    body = new_body

    assert_includes body, "%w[TERM HUP]",
                     "SIGTERM/SIGHUP are not trapped, so a harness timeout still leaves a half-desk"
    assert_match(/raise Interrupt/, body,
                 "the trap must RAISE, or the rescue that unwinds never runs")
    assert_match(/prior_traps\.each \{ \|sig, handler\| Signal\.trap\(sig, handler\) \}/, body,
                 "the handlers must be restored, or everything downstream of `new` inherits them")
  end

  test "the trap is installed inside an ensure that restores it" do
    body = new_body
    trap_at = body.index("prior_traps =")
    restore_at = body.index("prior_traps.each")
    ensure_at = body.rindex("ensure", restore_at)

    assert trap_at && restore_at && ensure_at, "the trap/restore pair moved"
    assert_operator ensure_at, :<, restore_at,
                    "the restore must sit in an ensure, or a raising bringup leaves the handler installed"
  end

  # --- capacity: refuse before the first side effect ---------------------------------

  test "capacity is preflighted BEFORE anything is created" do
    body = new_body
    preflight_at = body.index("preflight_capacity!")
    cut_at = body.index("ensure_git_worktree")

    assert preflight_at, "the capacity preflight is gone — a full band now cuts a desk it must roll back"
    assert_operator preflight_at, :<, cut_at,
                    "the preflight runs AFTER the worktree is cut, which is the whole thing it exists " \
                    "to avoid: an unwind is best-effort, creating nothing is not"
  end

  test "a resume skips the capacity preflight rather than refusing a repair" do
    Dir.mktmpdir do |tmp|
      env = File.join(tmp, "stack.env")
      File.write(env, "APP_PORT=3001\n")
      app = { "slug" => "repo" }
      script.define_singleton_method(:stack_env_path) { |_a, _t| env }
      script.define_singleton_method(:with_worktree_lock) { |&_b| raise "took the lock on a resume" }

      assert_nil script.preflight_capacity!(app, "already-here"),
                 "a provisioned desk already HOLDS its slot; re-running new on it is a repair, and " \
                 "refusing it would strand the desk half-built"
    end
  end

  # --- the redis band ----------------------------------------------------------------

  test "a bringup that grew the redis band unwinds the growth" do
    body = new_body

    assert_match(/unwinder\.on_success\("redis band growth"\)/, body,
                 "a failed bringup permanently inflates a band it never used a slot of")
    assert_match(/load_current_capacity != capacity_before/, body,
                 "the unwind must be registered only when the band ACTUALLY grew — otherwise a " \
                 "failed bringup would shrink a band someone else just grew")
    assert_match(/load_current_capacity <= capacity_before/, body,
                 "and it must report its own verdict: maybe_scale_in refuses to shrink below the " \
                 "floor or past a slot in use, which is not the same as having unwound")
  end

  def new_body
    src = File.read(Rails.root.join("bin/agent-worktree"))
    body = src[/when "new"(.*?)when "/m, 1]
    refute_nil body, "the `new` dispatch moved — re-point this test rather than deleting it"
    body
  end
end
