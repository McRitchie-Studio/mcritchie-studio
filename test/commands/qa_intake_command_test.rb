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
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir, "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"),
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
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir, "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}"),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "rolio", "--json",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    pr = JSON.parse(out).fetch("prs").first

    assert_equal "rolio", pr.fetch("app")
    assert_equal "McRitchie-Studio/rolio", pr.fetch("repo")
    assert_equal "missing-local-branch", pr.fetch("status")
  end

  # --- the occupied desk: its own label, not the generic attention bucket --
  #
  # The reclaim guard (task reclaim-guard-live-claim) writes a structured verdict
  # into the worktree registry: `withheld_reason` is the reason a git-eligible desk
  # was withheld from reclaim (a live builder claim, or a board record that could
  # not be read), nil when the desk is free. Before this feature, qa-intake never
  # consumed it, so a withheld desk fell through to the generic attention bucket
  # ("inspect listed issues and assign back to the owning agent") — strictly safe,
  # but unlabeled. These tests pin the label: an occupied desk is classified
  # `occupied`, leaves the attention bucket, and its action says to leave it alone,
  # quoting the registry's reason verbatim (the reason string — not a paraphrase —
  # is what distinguishes a live builder from an unreadable board).

  test "[unit] a withheld desk is labeled occupied and leaves the attention bucket" do
    intake = intake_for([occupied_worktree])

    occupied = intake.fetch("occupied")
    assert_equal 1, occupied.size, "the withheld desk must land in the occupied bucket"
    assert_equal "occupied", occupied.first.fetch("status")
    assert_empty intake.fetch("attention"),
      "an occupied desk must leave the generic attention bucket — 'inspect listed " \
      "issues and assign back to the owning agent' invites action on a desk whose " \
      "only correct action is to leave it alone"
    assert_empty intake.fetch("cleanup_candidates")
    assert_equal 1, intake.dig("summary", "occupied_desks")
  end

  test "[unit] the occupied action says leave this desk alone and quotes the reason" do
    intake = intake_for([occupied_worktree])
    action = intake.fetch("occupied").first.fetch("action")

    assert action.start_with?("occupied — "), "the label must lead the action, got: #{action}"
    assert_includes action, "leave this desk alone"
    assert_includes action, "held by a live builder claim (occupied-desk-demo)",
      "the registry's reason must be quoted verbatim so the operator sees WHY " \
      "(live claim with heartbeat age vs. unreadable board)"
  end

  # ABSENT-FIELD DEGRADATION (explicit, load-bearing): a registry written by
  # pre-guard bin/agent-worktree has no `withheld_reason` key at all. Intake must
  # behave exactly as it did before this feature — the desk stays in the generic
  # attention bucket and the occupied bucket is empty — so the merge order between
  # the guard PR and this consumer cannot break intake.
  test "[unit] a registry without withheld_reason degrades to today's generic attention" do
    legacy = occupied_worktree.tap { |worktree| worktree.delete("withheld_reason") }
    intake = intake_for([legacy])

    assert_empty intake.fetch("occupied"),
      "no field means no occupied verdict — pre-guard registries must be a no-op"
    assert_equal 0, intake.dig("summary", "occupied_desks")
    attention = intake.fetch("attention")
    assert_equal 1, attention.size, "the desk must fall back to the attention bucket, as before"
    assert_equal "inspect listed issues and assign back to the owning agent",
      attention.first.fetch("action"),
      "the pre-feature generic action must be preserved for pre-guard registries"
  end

  test "[unit] a blank or non-string withheld_reason does not mark a desk occupied" do
    ["", "   ", true, 7].each do |value|
      intake = intake_for([occupied_worktree.merge("withheld_reason" => value)])

      assert_empty intake.fetch("occupied"),
        "withheld_reason=#{value.inspect} is not a reason; the desk must degrade to " \
        "attention, never gain a label from a malformed field"
      assert_equal 1, intake.fetch("attention").size
    end
  end

  test "[integration] qa-intake --json splits occupied desks from attention" do
    registry = write_registry_with_occupied_desk

    out, err, status = Open3.capture3(
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "mcritchie-studio", "--no-gh", "--json",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    intake = JSON.parse(out)

    occupied = intake.fetch("occupied")
    assert_equal ["mcritchie-studio/occupied-desk-demo"], occupied.map { |worktree| worktree.fetch("label") }
    assert_equal "occupied", occupied.first.fetch("status")
    assert_includes occupied.first.fetch("action"), "leave this desk alone"

    attention_labels = intake.fetch("attention").map { |worktree| worktree.fetch("label") }
    refute_includes attention_labels, "mcritchie-studio/occupied-desk-demo",
      "the occupied desk must not double-report in attention"
    assert_includes attention_labels, "mcritchie-studio/dirty-desk-demo",
      "other attention desks must be untouched by the occupied split"

    assert_empty intake.fetch("cleanup_candidates")
    assert_equal 1, intake.dig("summary", "occupied_desks")
  end

  test "[integration] qa-intake text output prints the Occupied Desks section" do
    registry = write_registry_with_occupied_desk

    out, err, status = Open3.capture3(
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "mcritchie-studio", "--no-gh",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "Occupied Desks"
    assert_includes out, "[occupied] mcritchie-studio/occupied-desk-demo"
    assert_includes out, "held by a live builder claim (occupied-desk-demo)"

    attention_section = out[/Worktree Attention.*?(?=\nCleanup Candidates|\nOccupied Desks|\z)/m].to_s
    refute_includes attention_section, "occupied-desk-demo",
      "the occupied desk must leave the Worktree Attention section"
  end

  test "[integration] pre-guard registry yields no Occupied Desks section" do
    registry = write_registry_with_occupied_desk(withheld_reason: :omit)

    out, err, status = Open3.capture3(
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir),
      RbConfig.ruby, @script, "--registry", registry, "--apps", "mcritchie-studio", "--no-gh",
      chdir: @projects_dir
    )

    assert status.success?, "#{out}\n#{err}"
    refute_includes out, "Occupied Desks",
      "a registry written by pre-guard code must produce the pre-feature output shape"
    attention_section = out[/Worktree Attention.*?(?=\nCleanup Candidates|\z)/m].to_s
    assert_includes attention_section, "occupied-desk-demo",
      "without the field, the desk must fall back to Worktree Attention exactly as before"
    assert_includes attention_section, "inspect listed issues and assign back to the owning agent"
  end

  private

  def build_repo(slug = "mcritchie-studio")
    repo_dir = File.join(@projects_dir, slug)
    FileUtils.mkdir_p(repo_dir)
    git(repo_dir, "init", "-q")
    git(repo_dir, "remote", "add", "origin", "git@github.com:McRitchie-Studio/#{slug}.git")
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
          url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/124",
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
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    out
  end

  # A desk withheld from reclaim, as the reclaim guard's registry writes it: clean,
  # landed on base (git-eligible), NOT a cleanup candidate, and carrying the
  # structured `withheld_reason` verdict. The `issues` prose mirrors what
  # bin/agent-worktree's doctor emits for a held desk; qa-intake must decide from the
  # field, never that prose.
  def occupied_worktree(overrides = {})
    {
      "label" => "mcritchie-studio/occupied-desk-demo",
      "app" => "mcritchie-studio", "task" => "occupied-desk-demo",
      "worktree" => File.join(@projects_dir, "wt-occupied"), "health" => "running",
      "branch" => "feat/occupied-desk-demo", "head" => "abc1234", "base_ref" => "origin/release",
      "dirty" => false, "merged_to_origin_main" => true, "cleanup_candidate" => false,
      "withheld_reason" => "held by a live builder claim (occupied-desk-demo) — " \
                           "builder heartbeat 8s ago (lease TTL 120s)",
      "ahead_origin_main" => "0", "behind_origin_main" => "0",
      "issues" => ["clean and landed on origin/release, but held by a live builder claim " \
                   "(occupied-desk-demo) — builder heartbeat 8s ago (lease TTL 120s); withheld from reclaim"]
    }.merge(overrides)
  end

  def dirty_worktree_fixture
    {
      "label" => "mcritchie-studio/dirty-desk-demo",
      "app" => "mcritchie-studio", "task" => "dirty-desk-demo",
      "worktree" => File.join(@projects_dir, "wt-dirty"), "health" => "down",
      "branch" => "feat/dirty-desk-demo", "head" => "def5678", "base_ref" => "origin/release",
      "dirty" => true, "merged_to_origin_main" => false, "cleanup_candidate" => false,
      "ahead_origin_main" => "1", "behind_origin_main" => "0",
      "issues" => ["dirty worktree"]
    }
  end

  # Registry fixture holding one occupied desk and one ordinary attention desk.
  # `withheld_reason: :omit` drops the field entirely — the exact shape a pre-guard
  # bin/agent-worktree writes — for the absent-field degradation tests.
  def write_registry_with_occupied_desk(withheld_reason: :keep)
    occupied = occupied_worktree
    occupied.delete("withheld_reason") if withheld_reason == :omit

    path = File.join(@projects_dir, ".agents", "occupied-registry.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(
      "generated_at" => "2026-07-13T00:00:00Z",
      "apps" => [{
        "slug" => "mcritchie-studio", "display_name" => "McRitchie Studio",
        "repo" => File.join(@projects_dir, "mcritchie-studio"), "primary_port" => 3000,
        "range_start" => 3000, "range_end" => 3099, "status" => "active"
      }],
      "summary" => {},
      "worktrees" => [occupied, dirty_worktree_fixture]
    )}\n")
    path
  end

  # Run build_intake against fixture worktrees in a hermetic subprocess (same `load`
  # pattern as eval_intake) and parse the intake JSON it produces.
  def intake_for(worktrees)
    snippet = <<~RUBY
      require "json"
      load #{@script.inspect}
      worktrees = JSON.parse(#{JSON.generate(worktrees).inspect})
      puts JSON.generate(build_intake({}, [], [], worktrees, []))
    RUBY
    out, err, status = Open3.capture3(
      OutboundSeams.env("PROJECTS_DIR" => @projects_dir),
      RbConfig.ruby, "-e", snippet
    )
    assert status.success?, "#{out}\n#{err}"
    JSON.parse(out)
  end
end
