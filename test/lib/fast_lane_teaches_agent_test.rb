require "test_helper"
require_relative "../support/fake_task_derivation"

# [unit] `bin/task begin` works without `--agent` (devops-v3 piece 4c-i).
#
# RETARGETED. This file used to demand `--agent <soul>` on every documented begin
# line, because the build claim's stamp (devops.built_by + devops.builders) was
# the only author set review could read: omit it and bin/reviewer-select failed
# closed. Authors are now DERIVED from the PR's commits (Task#derived_authors —
# `<soul>@mcritchie.studio` emails and soul Co-Authored-By trailers), and the
# selector and the review-claim backstop read that set UNION any stamps. So the
# flag is optional, and this guard now pins the opposite teaching plus the
# property that makes it true.
#
# ARCHIVES ARE EXCLUDED: `docs/agents/archive/**` holds FROZEN snapshots, not
# instructions, and AGENTS.md says to leave them as written.
class FastLaneTeachesAgentTest < ActiveSupport::TestCase
  HUB = "mcritchie-studio"
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/4001"
  INVOCATION = "bin/task begin"
  CREATE_FLAG = "--title"

  # The canonical recipes an agent copies: the two entry maps the projects-root
  # CLAUDE.md / AGENTS.md generate from, and the build SOP.
  CANONICAL = %w[docs/agents/claude.md docs/agents/index.md docs/agents/modules/building-sop.md].freeze

  # Phrases that taught the old requirement. A doc carrying one would send an
  # agent back to treating the flag as load-bearing for review.
  STALE_TEACHING = [
    "Omit it and the selector fails CLOSED",
    "it is what makes review able to exclude you",
    "stamps you as an author**, which keeps you off your own"
  ].freeze

  def self.create_invocation?(line)
    line.include?(INVOCATION) && line.include?(CREATE_FLAG)
  end

  def self.docs_naming_begin
    Dir.glob(Rails.root.join("docs/**/*.md")).sort
       .reject { |path| path.include?("/agents/archive/") }
       .select { |path| File.read(path).include?(INVOCATION) }
       .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  DOCS = docs_naming_begin.freeze

  test "the derived doc set actually found the docs that carry the invocation" do
    refute_empty DOCS, "the docs glob matched nothing — this guard is inspecting no files"
    CANONICAL.each { |rel| assert_includes DOCS, rel }
  end

  test "the canonical begin recipes work without --agent" do
    CANONICAL.each do |rel|
      lines = Rails.root.join(rel).read.each_line.select { |line| self.class.create_invocation?(line) }
      refute_empty lines, "#{rel} no longer shows a begin create line"
      lines.each do |line|
        # The COMMAND only: from `bin/task begin` to the closing backtick (a table
        # cell) or the end of the line, so prose beside it may name the flag.
        command = line[line.index(INVOCATION)..].split("`").first
        refute_includes command, "--agent ", "#{rel} still puts --agent on its begin recipe: #{command.strip}"
      end
    end
  end

  test "no live doc still teaches that --agent is required for review" do
    offenders = DOCS.flat_map do |rel|
      body = Rails.root.join(rel).read
      STALE_TEACHING.select { |phrase| body.include?(phrase) }.map { |phrase| "#{rel}: #{phrase}" }
    end

    assert_empty offenders, "these docs still teach the retired --agent requirement: #{offenders.join('; ')}"
  end

  # THE PROPERTY that makes the flag optional: a task with NO stamp at all still
  # has KNOWN authors, taken from its PR's commits, and they are excluded.
  test "reviewer selection knows the authors of an unstamped task from its PR" do
    task = Task.create!(title: "unstamped author sample task", stage: "submitted",
                        metadata: { "devops" => { "shape" => "ui-only", "repositories" => [HUB], "pr_url" => PR_URL } })

    unknown = ReviewerSelector.new(task, pr_authors: []).decision
    refute unknown["builder_known"], "with no stamp AND no derived author the selector still fails closed"

    decision = ReviewerSelector.new(task, pr_authors: %w[shannon]).decision
    assert decision["builder_known"], "the PR's commit author is enough; no --agent stamp is needed"
    assert_equal %w[shannon], decision["builders"]
    refute_includes decision["reviewers"].map { |r| r["slug"] }, "shannon", "the derived author is never seated"
  end

  test "the review-claim backstop refuses a derived author on an unstamped task" do
    task = Task.create!(title: "unstamped claim sample task", stage: "submitted",
                        metadata: { "devops" => { "shape" => "backend", "repositories" => [HUB], "pr_url" => PR_URL } })

    refute TaskReviewClaim.self_review?(task.slug, "jasper")
    TaskDerivedFacts.stub(:enabled?, true) do
      Github::TaskDerivation.stub(:new, FakeTaskDerivation.new(authors: { PR_URL => %w[jasper] })) do
        Github::TaskDerivation.reset_shared!
        assert TaskReviewClaim.self_review?(task.slug, "jasper")
      end
    end
  ensure
    Github::TaskDerivation.reset_shared!
  end
end
