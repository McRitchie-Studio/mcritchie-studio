require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# Unit coverage for bin/qa-intake's PR classification. The script guards its CLI
# dispatch behind `$PROGRAM_NAME == __FILE__`, so `load`ing it in a hermetic
# subprocess defines the pure classifiers (status_label_for_pr / pr_action /
# pr_notes) without parsing ARGV or reading a registry.
#
# Regression: a PR GitHub calls clean+mergeable+green must NOT be flagged
# needs-agent / returned to the feature agent purely because its local worktree
# is N commits behind origin/release. PR #124 and #125 were both bounced for a
# no-op rebase despite mergeStateStatus=CLEAN. See task fix-qa-intake-merge-signal.
class QaIntakeCommandTest < ActiveSupport::TestCase
  BEHIND_ISSUE = "branch is 3 commit(s) behind origin/release; rebase before QA handoff".freeze

  def setup
    @script = Rails.root.join("bin/qa-intake").to_s
    @projects_dir = Dir.mktmpdir("qa-intake-command")
  end

  def teardown
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  # --- the bug: clean merge vs. local staleness ----------------------------

  test "[unit] clean mergeable PR behind base classifies avi-ready not needs-agent" do
    label = classify(clean_pr, behind_worktree)

    assert_equal "avi-ready", label,
      "a clean+mergeable+green PR that is merely behind origin/release must not be needs-agent"
  end

  test "[unit] clean PR behind base yields an Avi-review action not return-to-agent" do
    action = action_for(clean_pr, behind_worktree)

    assert_includes action, "Avi can review"
    refute_includes action, "return to the feature agent"
  end

  test "[unit] clean PR behind base downgrades staleness to an informational note" do
    notes = notes_for(clean_pr, behind_worktree)
    behind_note = notes.find { |note| note.include?("behind origin/release") }

    refute_nil behind_note, "expected a note mentioning the behind-base count"
    assert behind_note.start_with?("info:"), "staleness must be informational, got: #{behind_note}"
    assert_includes behind_note, "no action needed"
    assert_includes notes, "merge=CLEAN"
  end

  # --- preservation: every other needs-agent trigger is unchanged ----------

  test "[unit] clean PR with a genuine dirty blocker still needs-agent" do
    worktree = behind_worktree.merge(
      "dirty" => true,
      "issues" => [BEHIND_ISSUE, "dirty worktree"]
    )

    assert_equal "needs-agent", classify(clean_pr, worktree)
  end

  test "[unit] GitHub-reported BEHIND with a stale branch still needs-agent" do
    # mergeStateStatus BEHIND = head out of date under up-to-date branch
    # protection, where the rebase is genuinely required (not a no-op).
    pr = { "mergeStateStatus" => "BEHIND", "isDraft" => false }

    assert_equal "needs-agent", classify(pr, behind_worktree)
  end

  test "[unit] conflicting PR behind base still needs-agent" do
    pr = { "mergeStateStatus" => "DIRTY", "mergeable" => "CONFLICTING", "isDraft" => false }

    assert_equal "needs-agent", classify(pr, behind_worktree)
  end

  test "[unit] clean PR with no staleness is unchanged avi-ready" do
    worktree = behind_worktree.merge("behind_origin_main" => "0", "issues" => [])

    assert_equal "avi-ready", classify(clean_pr, worktree)
  end

  # --- the occupied desk: never recommend destroying it --------------------
  #
  # qa-intake is the conductor's FRONT DOOR for destruction: it prints a
  # `remove … --yes` per desk it calls a cleanup candidate, and `remove --yes` is the
  # one path the reclaim guard deliberately does not block (it is the operator's
  # override). So a wrong recommendation here destroys a live builder's desk even
  # though every automatic path correctly withholds it.
  #
  # It used to decide by substring-matching the issue PROSE:
  #   issues = Array(worktree["issues"]).join("; ")
  #   ... if issues.include?("cleanup candidate")
  # A held desk's issue reads "…; not a cleanup candidate" — which CONTAINS
  # "cleanup candidate". The negation read as an affirmation. These tests pin the
  # structured verdict (`cleanup_candidate` / `withheld_reason`) as the only input.

  test "[unit] a withheld desk is never nominated for cleanup, even if its prose says 'cleanup candidate'" do
    # The exact string the old code tripped on. If attention_action ever goes back to
    # substring-matching prose, this goes red.
    action = attention_action_for(held_worktree(
      "issues" => ["clean and landed on origin/release, but held by a live builder claim " \
                   "(reclaim-guard-live-claim) — builder heartbeat 8s ago; not a cleanup candidate"]
    ))

    refute_includes action, "run cleanup workflow",
      "qa-intake recommended cleanup for a desk with a LIVE builder on it — the substring " \
      "match on 'cleanup candidate' inverted the negation. This is the reclaim incident, " \
      "re-entered through the conductor's front door."
    refute_includes action, "remove"
  end

  test "[unit] a withheld desk's action names the reason and says to leave it alone" do
    action = attention_action_for(held_worktree)

    assert_includes action, "leave this desk alone"
    assert_includes action, "live builder claim",
      "the operator must be told WHY the desk is off-limits, not merely that it is"
  end

  test "[unit] a desk withheld for an UNREADABLE board is also not nominated" do
    # The other withhold cause. A boolean named for the live-claim case would misreport
    # this one; the reason string carries it.
    action = attention_action_for(held_worktree(
      "withheld_reason" => "bound to task foo, but the board record could not be read",
      "issues" => ["clean and landed on origin/release, but the board record could not be read"]
    ))

    refute_includes action, "run cleanup workflow"
    assert_includes action, "board record could not be read"
  end

  # Positive control: the guard must not pass by simply never nominating anything.
  test "[unit] a genuinely free merged desk is still nominated for cleanup" do
    action = attention_action_for(held_worktree(
      "cleanup_candidate" => true,
      "withheld_reason" => nil,
      "issues" => ["branch is merged to origin/release and clean; cleanup candidate"]
    ))

    assert_includes action, "run cleanup workflow",
      "a free, merged desk must still be offered for cleanup — otherwise this guard " \
      "is just a disabled feature wearing a safety label"
  end

  # --- end-to-end through bin/qa-intake --json -----------------------------

  test "[integration] qa-intake queues a clean behind-base PR as avi-ready" do
    repo_dir = build_repo
    registry = write_registry(repo_dir, branch: "feat/fix-qa-intake-merge-signal", behind: "3")
    fake_bin = write_fake_gh(branch: "feat/fix-qa-intake-merge-signal", merge_state: "CLEAN")

    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "mcritchie-studio", "--json",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    pr = JSON.parse(out).fetch("prs").first

    assert_equal "avi-ready", pr.fetch("status")
    assert_includes pr.fetch("action"), "Avi can review"
    refute_includes pr.fetch("action"), "return to the feature agent"
    info = pr.fetch("notes").find { |note| note.start_with?("info:") && note.include?("behind origin/release") }
    refute_nil info, "expected an informational behind-base note, got: #{pr.fetch("notes").inspect}"
    assert_includes info, "no action needed"
  end

  test "[integration] qa-intake discovers release-managed apps outside the worktree registry" do
    build_repo("rolio")
    registry = write_registry_without_apps
    fake_bin = write_fake_gh(branch: "feat/rolio-demo", merge_state: "CLEAN")

    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "rolio", "--json",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    pr = JSON.parse(out).fetch("prs").first

    assert_equal "rolio", pr.fetch("app")
    assert_equal "amcritchie/rolio", pr.fetch("repo")
    assert_equal "missing-local-branch", pr.fetch("status")
  end

  private

  def build_repo(slug = "mcritchie-studio")
    repo_dir = File.join(@projects_dir, slug)
    FileUtils.mkdir_p(repo_dir)
    git(repo_dir, "init", "-q")
    git(repo_dir, "remote", "add", "origin", "git@github.com:amcritchie/#{slug}.git")
    repo_dir
  end

  def write_registry(repo_dir, branch:, behind:)
    path = File.join(@projects_dir, ".agents", "intake-registry.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(
      "generated_at" => "2026-06-23T00:00:00Z",
      "apps" => [{
        "slug" => "mcritchie-studio", "display_name" => "McRitchie Studio",
        "repo" => repo_dir, "primary_port" => 3000,
        "range_start" => 3000, "range_end" => 3099, "status" => "active"
      }],
      "summary" => {},
      "worktrees" => [{
        "label" => "mcritchie-studio/fix-qa-intake-merge-signal",
        "app" => "mcritchie-studio", "task" => "fix-qa-intake-merge-signal",
        "worktree" => File.join(@projects_dir, "wt"), "health" => "down",
        "branch" => branch, "base_ref" => "origin/release",
        "dirty" => false, "merged_to_origin_main" => false, "cleanup_candidate" => false,
        "ahead_origin_main" => "2", "behind_origin_main" => behind,
        "issues" => ["branch is #{behind} commit(s) behind origin/release; rebase before QA handoff"]
      }]
    )}\n")
    path
  end

  def write_registry_without_apps
    path = File.join(@projects_dir, ".agents", "empty-registry.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(
      "generated_at" => "2026-06-23T00:00:00Z",
      "apps" => [],
      "summary" => {},
      "worktrees" => []
    )}\n")
    path
  end

  def write_fake_gh(branch:, merge_state:)
    dir = File.join(@projects_dir, "fake-bin")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      if ARGV[0, 2] == ["pr", "list"]
        puts JSON.generate([{
          number: 124, title: "Clean behind-base PR",
          url: "https://github.com/amcritchie/mcritchie-studio/pull/124",
          isDraft: false, headRefName: #{branch.inspect}, baseRefName: "release",
          mergeStateStatus: #{merge_state.inspect}, mergeable: "MERGEABLE",
          reviewDecision: "", updatedAt: "2026-06-23T00:00:00Z",
          author: { login: "steffon" }, labels: []
        }])
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end

  def git(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
  end

  def clean_pr
    { "mergeStateStatus" => "CLEAN", "mergeable" => "MERGEABLE", "isDraft" => false }
  end

  def behind_worktree
    {
      "dirty" => false,
      "merged_to_origin_main" => false,
      "cleanup_candidate" => false,
      "ahead_origin_main" => "2",
      "behind_origin_main" => "3",
      "health" => "down",
      "issues" => [BEHIND_ISSUE]
    }
  end

  # A desk that is clean and landed on base — so cleanup_ready? says yes — but is HELD:
  # a builder is sitting at it with a live claim. Structurally identical to a reclaimable
  # desk; only the claim tells them apart.
  def held_worktree(overrides = {})
    {
      "label" => "mcritchie-studio/reclaim-guard-live-claim",
      "app" => "mcritchie-studio", "task" => "reclaim-guard-live-claim",
      "branch" => "feat/reclaim-guard-live-claim", "base_ref" => "origin/release",
      "dirty" => false, "merged_to_origin_main" => true,
      "cleanup_candidate" => false,
      "withheld_reason" => "held by a live builder claim (reclaim-guard-live-claim) — " \
                           "builder heartbeat 8s ago (lease TTL 120s)",
      "ahead_origin_main" => "0", "behind_origin_main" => "0",
      "issues" => []
    }.merge(overrides)
  end

  def attention_action_for(worktree)
    eval_intake("puts attention_action(worktree)", clean_pr, worktree).strip
  end

  def classify(pr, worktree)
    eval_intake("puts status_label_for_pr(pr, worktree)", pr, worktree).strip
  end

  def action_for(pr, worktree)
    eval_intake("puts pr_action(status_label_for_pr(pr, worktree), pr, worktree)", pr, worktree).strip
  end

  def notes_for(pr, worktree)
    JSON.parse(eval_intake("puts JSON.generate(pr_notes(pr, worktree))", pr, worktree))
  end

  # Load bin/qa-intake as a library in an isolated subprocess (the dispatch guard
  # keeps `load` side-effect-free) and run a one-liner against fixture PR data.
  def eval_intake(body, pr, worktree)
    snippet = <<~RUBY
      require "json"
      load #{@script.inspect}
      pr = JSON.parse(#{JSON.generate(pr).inspect})
      worktree = JSON.parse(#{JSON.generate(worktree).inspect})
      #{body}
    RUBY
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    out
  end
end
