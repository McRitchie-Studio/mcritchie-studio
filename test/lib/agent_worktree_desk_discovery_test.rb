# frozen_string_literal: true

# bin/agent-worktree's DESK AUDIT: which desks the sweep sees, how it judges a discovered
# repo's desk, and how `remove` finds the desk it was named. Three defects from the
# 2026-09-25/26 desk audit (task desk-audit-sees-every-desk):
#
#   1. snapshot scanned only <repo>/.worktrees/, so a worktree git had registered anywhere
#      else (<projects>/.worktrees/<repo>/, a sibling <repo>.worktrees/, a scratchpad) never
#      reached the Desks panel;
#   2. `cleanup --reclaim` withheld EVERY desk of a discovered repo (66 of 70 held desks,
#      ~50 clean and merged), because such a desk can carry no bound task;
#   3. `remove studio-engine studio-s3-ignores-qa_env` normalized `_` to `-` before looking,
#      and answered "missing worktree" about a desk that was there.
#
# Every check here builds real git repos in a tmpdir — a test for discovery must own the
# thing being discovered — and points PROJECTS_DIR at it, so HUB_DIR has no satellites.yml
# and the registry holds mcritchie-studio alone. The script is `load`ed in a subprocess
# (its dispatch suppressed by the main guard), as in test/lib/agent_worktree_test.rb, except
# for `remove`, which drives the real binary because the defect sat in its dispatch.
require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/session_env"

class AgentWorktreeDeskDiscoveryTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-worktree", __dir__)

  GIT_IDENTITY = {
    "GIT_AUTHOR_NAME" => "Desk Test", "GIT_AUTHOR_EMAIL" => "desk@test.invalid",
    "GIT_COMMITTER_NAME" => "Desk Test", "GIT_COMMITTER_EMAIL" => "desk@test.invalid"
  }.freeze

  def setup
    # realpath: git reports worktree paths realpath'd, and /var and /tmp are symlinks on macOS.
    @root = File.realpath(Dir.mktmpdir("desk-discovery"))
  end

  def teardown
    FileUtils.rm_rf(@root) if @root
  end

  # --- 1. snapshot sees a worktree wherever git registered it ---------------------------

  def test_snapshot_finds_worktrees_registered_outside_the_managed_tree
    hub = init_repo("mcritchie-studio")
    gem = init_repo("gem-lib")
    git!(hub, "worktree", "add", "-q", File.join(@root, "scratch", "hub-scratch-desk"), "-b", "feat/hub-scratch")
    git!(gem, "worktree", "add", "-q", File.join(@root, ".worktrees", "gem-lib", "projects-root-desk"), "-b", "feat/pr")
    git!(hub, "worktree", "add", "-q", File.join(hub, ".worktrees", "managed-desk"), "-b", "feat/managed")

    out = run_in_script(<<~RUBY)
      records = stack_records
      print records.map { |r| [worktree_label(r), r[:dir]] }.sort.inspect
    RUBY

    assert_equal [
      ["gem-lib/projects-root-desk", File.join(@root, ".worktrees", "gem-lib", "projects-root-desk")],
      ["mcritchie-studio/hub-scratch-desk", File.join(@root, "scratch", "hub-scratch-desk")],
      ["mcritchie-studio/managed-desk", File.join(hub, ".worktrees", "managed-desk")]
    ].inspect, out,
                 "every git-registered worktree is a desk of its REAL repo, wherever it lives — and " \
                 "the primary checkouts themselves are not desks"
  end

  # The ledger keys on the path string: listing one desk twice (glob + git) or under a new
  # spelling would open a second DeskRecord for a desk it already tracks.
  def test_a_managed_desk_git_also_lists_is_enumerated_once_under_its_glob_path
    hub = init_repo("mcritchie-studio")
    git!(hub, "worktree", "add", "-q", File.join(hub, ".worktrees", "managed-desk"), "-b", "feat/managed")

    out = run_in_script(<<~RUBY)
      print stack_dirs(apps.fetch("mcritchie-studio")).inspect
    RUBY

    assert_equal [File.join(hub, ".worktrees", "managed-desk")].inspect, out
  end

  # --- 2. reclaim judges a discovered repo's desk by git -------------------------------

  def test_reclaim_nominates_a_clean_merged_pushed_idle_discovered_desk_and_names_each_hold
    gem = gem_with_origin
    desk(gem, "clean-merged") do |dir|
      commit!(dir, "landed.txt")
      git!(dir, "push", "-q", "origin", "HEAD:refs/heads/feat/clean-merged", "HEAD:refs/heads/main")
    end
    desk(gem, "dirty-desk") { |dir| File.write(File.join(dir, "scratch.txt"), "wip") }
    desk(gem, "unpushed-desk") { |dir| commit!(dir, "local-only.txt") }
    desk(gem, "unmerged-desk") do |dir|
      commit!(dir, "in-review.txt")
      git!(dir, "push", "-q", "origin", "HEAD:refs/heads/feat/unmerged-desk")
    end
    git!(gem, "fetch", "-q", "origin")

    out = partition(idle: true)

    assert_includes out, "FREE gem-lib/clean-merged",
                    "clean, nothing unpushed, merged into origin/main, no open PR, idle: reclaimable"
    assert_match %r{HELD gem-lib/dirty-desk: tree is dirty}, out
    assert_match %r{HELD gem-lib/unpushed-desk: 1 commit\(s\) on HEAD are on no remote \(unpushed\)}, out
    assert_match %r{HELD gem-lib/unmerged-desk: unmerged: HEAD is not contained in origin/main}, out
    assert_match %r{RATIONALE gem-lib/clean-merged: merged into origin/main, nothing unpushed, tree clean}, out
  end

  def test_the_idle_window_still_holds_a_fresh_discovered_desk_git_would_clear
    gem = gem_with_origin
    desk(gem, "fresh-desk") { |_dir| nil }

    out = partition(idle: false)

    assert_match %r{HELD gem-lib/fresh-desk: the desk is only .* idle window}, out,
                 "git clearing a desk is not permission to skip the age guard: a fresh desk is " \
                 "git-identical to a merged one"
  end

  def test_an_open_pr_or_an_unanswerable_github_holds_a_discovered_desk
    gem = gem_with_origin
    desk(gem, "pr-desk") { |_dir| nil }

    open_pr = partition(idle: true, env: { "AGENT_WORKTREE_OPEN_PR" => "41" })
    no_gh = partition(idle: true, env: { "AGENT_WORKTREE_OPEN_PR" => "unavailable" })

    assert_match %r{HELD gem-lib/pr-desk: an OPEN pull request \(#41\)}, open_pr
    assert_match %r{HELD gem-lib/pr-desk: could not ask GitHub .* no board record to fall back on}, no_gh,
                 "a bound desk falls back on its board record when gh is out; a discovered desk has none"
  end

  def test_a_discovered_ship_workspace_stays_withheld
    gem = gem_with_origin
    git!(gem, "worktree", "add", "-q", "--detach", File.join(gem, ".worktrees", "_ship"), "origin/main")

    out = partition(idle: true, env: { "AGENT_WORKTREE_RELEASE_CLAIM" => "none" })

    assert_match %r{HELD gem-lib/_ship: a release workspace \(_ship\) in a discovered repo stays withheld}, out
  end

  # --- review rework: the ways the widened sweep could call an in-use desk safe ----------

  # Carl's reproduction. A REGISTERED app now lists every worktree git knows, including
  # Claude Code's `.claude/worktrees/*` — unbound, so the unbound fail-open read it FREE
  # while a session worked in it. Listed, yes; nominated, never.
  def test_a_desk_outside_the_managed_root_is_listed_but_never_nominated
    hub = repo_with_origin("mcritchie-studio")
    desk(hub, "cc-session", at: File.join(hub, ".claude", "worktrees", "cc-session")) { |_dir| nil }
    desk(hub, "managed-twin") { |_dir| nil }
    gem = repo_with_origin("gem-lib")
    desk(gem, "projects-root-desk", at: File.join(@root, ".worktrees", "gem-lib", "projects-root-desk")) { |_dir| nil }

    hub_out = partition(idle: true, app: "mcritchie-studio")
    gem_out = partition(idle: true)

    assert_match %r{HELD mcritchie-studio/cc-session: outside the managed desk root .* remove it deliberately}, hub_out
    assert_includes hub_out, "FREE mcritchie-studio/managed-twin",
                    "control: the same clean, merged, idle desk inside .worktrees is still nominated"
    assert_match %r{HELD gem-lib/projects-root-desk: outside the managed desk root}, gem_out
  end

  # Steffon's reproduction. A two-repo task cuts `feat/<slug>` in both repos; a cache keyed
  # on the branch alone handed the hub's "no open PR" to the gem desk.
  def test_the_open_pr_answer_is_never_shared_across_repos_on_one_branch_name
    out = run_in_script(<<~RUBY)
      def compute_open_pr_for_branch(record, _branch)
        record[:app]["repo"].end_with?("gem-lib") ? [:open, "12"] : [:none, nil]
      end
      hub = { app: { "repo" => "/p/mcritchie-studio" }, branch: "feat/two-repo", dir: "/p/mcritchie-studio/.worktrees/two-repo" }
      gem = { app: { "repo" => "/p/gem-lib" }, branch: "feat/two-repo", dir: "/p/gem-lib/.worktrees/two-repo" }
      print [open_pr_for_branch(hub), open_pr_for_branch(gem)].inspect
    RUBY

    assert_equal '[[:none, nil], [:open, "12"]]', out,
                 "the gem desk's own open PR must be asked about, not read from the hub's answer"
  end

  # A branch NAME is reused — a squash-merged branch keeps taking commits — so only a PR
  # merged at exactly the desk's HEAD vouches for it.
  def test_a_merged_pr_counts_only_when_its_head_is_the_desks_head
    head = "a" * 40
    out = run_in_script(<<~RUBY, env: { "AGENT_WORKTREE_MERGED_PR" => nil })
      def command_available?(_n) = true
      def github_repo_slug(_d) = "o/gem-lib"
      def git_value(_d, *_a) = #{head.inspect}
      PRS = { stale: '[{"number":7,"headRefOid":"#{"b" * 40}"}]', current: '[{"number":9,"headRefOid":"#{head}"}]' }
      def capture_status(*_a) = [true, PRS.fetch($which), ""]
      record = { dir: "/p/gem-lib/.worktrees/d", branch: "feat/d" }
      $which = :stale
      stale = merged_pr_for_branch(record)
      $which = :current
      print [stale, merged_pr_for_branch(record)].inspect
    RUBY

    assert_equal '[[:none, nil], [:merged, "9"]]', out,
                 "a PR merged at an older commit of the same branch says nothing about the commits in the desk"
  end

  # An idle, clean, merged desk can still hold a hand-edited `.env.local`: gitignored, so
  # `git status --porcelain` is blind to it, and a teardown deletes it.
  def test_gitignored_work_edited_since_the_desk_was_cut_holds_it
    gem = repo_with_origin("gem-lib", ignore: ".env*\ntmp/\n")
    desk(gem, "env-edited") { |dir| File.write(File.join(dir, ".env.local"), "SECRET=mine") }
    desk(gem, "tmp-only") { |dir| FileUtils.mkdir_p(File.join(dir, "tmp")) && File.write(File.join(dir, "tmp", "x"), "1") }

    out = partition(idle: true, age: 2 * 3600)

    assert_match %r{HELD gem-lib/env-edited: gitignored work changed since the desk was cut \(\.env\.local\)}, out
    assert_includes out, "FREE gem-lib/tmp-only", "regenerable ignored paths (tmp/) never hold a desk"
  end

  # --- 3. remove finds the desk by its real name first ---------------------------------

  def test_remove_resolves_a_desk_whose_slug_holds_an_underscore
    gem = gem_with_origin
    desk(gem, "studio-s3-ignores-qa_env") { |_dir| nil }

    out, err, = Open3.capture3(env, "ruby", BIN, "remove", "gem-lib", "studio-s3-ignores-qa_env")
    said = "#{out}#{err}"

    refute_includes said, "missing worktree", "the desk exists; normalizing `_` to `-` looked elsewhere"
    assert_includes said, "gem-lib/studio-s3-ignores-qa_env"
    assert Dir.exist?(File.join(gem, ".worktrees", "studio-s3-ignores-qa_env")), "a dry run destroys nothing"
  end

  def test_remove_still_normalizes_a_name_no_desk_matches_exactly
    gem = gem_with_origin
    desk(gem, "plain-desk") { |_dir| nil }

    out, err, = Open3.capture3(env, "ruby", BIN, "remove", "gem-lib", "Plain_Desk")

    refute_includes "#{out}#{err}", "missing worktree"
    assert_includes "#{out}#{err}", "gem-lib/plain-desk"
  end

  # A path must BE a desk: the primary checkout was accepted as a remove candidate.
  def test_remove_refuses_a_path_that_is_not_one_of_the_apps_desks
    gem = gem_with_origin
    desk(gem, "a-real-desk") { |_dir| nil }

    out, err, = Open3.capture3(env, "ruby", BIN, "remove", "gem-lib", gem)
    said = "#{out}#{err}"

    assert_includes said, "not a desk of gem-lib: #{gem}"
    refute_includes said, "remove candidate"
  end

  def test_the_primary_checkout_is_refused_however_it_is_reached
    gem = gem_with_origin

    # The app is built inline, not looked up: a lookup that aborted ("unknown app") would also
    # read as REFUSED and prove nothing — measured, it did exactly that.
    out = run_in_script(<<~RUBY)
      app = { "slug" => "gem-lib", "repo" => #{gem.inspect} }
      verdicts = [#{(gem + "/").inspect}, #{File.join(gem, ".worktrees", "a-desk").inspect}].map do |dir|
        refuse_primary_checkout!(app, dir)
        "ALLOWED"
      rescue SystemExit
        "REFUSED"
      end
      print verdicts.inspect
    RUBY

    assert_equal '["REFUSED", "ALLOWED"]', out,
                 "the primary is refused however it is spelled, and a desk is not — the guard must not " \
                 "depend on stack_dirs happening to exclude the primary"
  end

  private

  def env(extra = {})
    SessionEnv.neutralized.merge(GIT_IDENTITY).merge("PROJECTS_DIR" => @root, "AGENT_WORKTREE_DESK_SYNC" => "off")
              .merge(extra)
  end

  def git!(dir, *args)
    out, err, status = Open3.capture3(env, "git", "-C", dir, *args)
    raise "git #{args.join(" ")} failed in #{dir}: #{err}" unless status.success?

    out
  end

  def commit!(dir, file)
    File.write(File.join(dir, file), file)
    git!(dir, "add", file)
    git!(dir, "commit", "-q", "-m", file)
  end

  def init_repo(name)
    dir = File.join(@root, name)
    FileUtils.mkdir_p(dir)
    git!(dir, "init", "-q", "-b", "main")
    commit!(dir, "README")
    dir
  end

  # A discovered repo (not in the registry) with a bare origin, main pushed, origin/HEAD set.
  def gem_with_origin = repo_with_origin("gem-lib")

  def repo_with_origin(name, ignore: nil)
    origin = File.join(@root, "origins", "#{name}.git")
    FileUtils.mkdir_p(origin)
    git!(origin, "init", "-q", "--bare", "-b", "main")
    repo = init_repo(name)
    if ignore
      File.write(File.join(repo, ".gitignore"), ignore.gsub("\\n", "\n"))
      git!(repo, "add", ".gitignore")
      git!(repo, "commit", "-q", "-m", "ignore")
    end
    git!(repo, "remote", "add", "origin", origin)
    git!(repo, "push", "-q", "-u", "origin", "main")
    git!(repo, "remote", "set-head", "origin", "main")
    repo
  end

  def desk(repo, name, at: nil)
    dir = at || File.join(repo, ".worktrees", name)
    git!(repo, "worktree", "add", "-q", dir, "-b", "feat/#{name}", "origin/main")
    yield dir
    dir
  end

  # The sweep's own partition over the gem repo, one line per desk. `idle: true` stubs the
  # desk AGE and MTIME seams only — every other guard runs for real.
  # `age:` is the desk's stubbed age in seconds; the ignored-work check measures edits
  # against it, so a test that plants a file NOW passes an age that puts the cut before it.
  def partition(idle:, env: {}, app: "gem-lib", age: 10 * 86_400)
    stubs = idle ? "def desk_age_seconds(_r) = #{age}\ndef desk_touched_recently?(_r) = false\n" : ""
    run_in_script(<<~RUBY, env: { "AGENT_WORKTREE_OPEN_PR" => "none", "AGENT_WORKTREE_TASK_JSON" => nil }.merge(env))
      #{stubs}
      free, withheld = cleanup_partition(sweep_app_for(#{app.inspect}))
      lines = free.map { |r| "FREE \#{worktree_label(r)}" } +
              free.map { |r| "RATIONALE \#{worktree_label(r)}: \#{reclaim_evidence(r)[:rationale]}" } +
              withheld.map { |r, reason| "HELD \#{worktree_label(r)}: \#{reason}" }
      print lines.join("\\n")
    RUBY
  end

  def run_in_script(body, env: {})
    out, err, status = Open3.capture3(env(env), "ruby", "-e", "load #{BIN.inspect}\n#{body}")
    flunk "agent-worktree subprocess failed (exit #{status.exitstatus}):\n#{err}" unless status.success?

    out.strip
  end
end
