# frozen_string_literal: true

require "test_helper"

# Who may merge is a rule the reviewers read from these pages, and the page a
# reviewer is spawned on is the only copy of it that reviewer sees. So every page
# that seats the documentation seat names the rule and the command that measures
# it, and the primary SOP runs that command before the merge it guards.
class DocsSeatMergeRuleDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive, with wrapped lines read as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  LIGHT_PAGE = "agents/carl/sops/pr-review-light.md"

  # page => the sentence it must carry
  RULE_PAGES = {
    "agents/carl/sops/pr-review-primary.md" => /Xan, the documentation seat, merges a docs-shape PR only/,
    "agents/carl/sops/pr-review.md" => /documentation seat merges docs-shape PRs only/,
    "agents/carl/sops/pr-review-light.md" => /documentation seat merges a docs-shape PR only as its PRIMARY/,
    "modules/focus-session.md" => /documentation seat merges docs-shape PRs only/,
    "modules/pr-review-sop.md" => /documentation seat merges no other shape/,
    "agents/xan/role.md" => /Docs-shape only/,
    "agents/xan/HEARTBEAT.md" => /every other diff is Carl's to merge/,
    "agents/xan/claude-agent.md" => /never merges a code PR/
  }.freeze

  test "[docs] every page that seats the documentation seat names the merge rule and its command" do
    RULE_PAGES.each do |page, sentence|
      body = norm(page)

      assert body.match?(sentence), "#{page} must state that the documentation seat merges docs-shape PRs only"
      next if page == LIGHT_PAGE # a light never merges, so it has no command to run

      assert body.include?("bin/merge-permit"), "#{page} must name the command that measures the diff"
    end
  end

  test "[docs] the primary SOP runs the permit before the merge and binds the verdict to a head" do
    body = File.read(AGENTS.join("agents/carl/sops/pr-review-primary.md"))
    permit = body.index("bin/merge-permit <task-slug> --agent <your-soul> --head <validated-head>")
    merge = body.index("gh pr merge <feat-pr> --merge --match-head-commit <validated-head>")

    assert permit, "step 6 must run bin/merge-permit with the soul and the validated head"
    assert merge, "step 6 must keep the head-pinned merge"
    assert_operator permit, :<, merge, "the permit is asked before the merge it guards"
    assert_match(/--record-scout-report <task-slug>.*?--head <validated-head>/m, body,
                 "step 5 must record the scout report with --head, or the documentation seat's merge is refused")
    assert_includes norm("agents/carl/sops/pr-review-primary.md"), "measured from the PR's own files at the head being merged, never from the task's declared shape"
  end

  test "[docs] the tier A row sends a refused diff to carl" do
    body = norm("modules/focus-session.md")

    assert_includes body, "records its verdict with --head, and merges on bin/merge-permit's permit"
    assert_match(/If Xan reports a refusal .* the PR is tier B: spawn carl/, body)
  end

  test "[docs] the commands the pages print are the script's own flags" do
    script = File.read(Rails.root.join("bin", "lib", "merge_permit_cli.rb"))
    cycle = File.read(Rails.root.join("bin", "devops-cycle"))

    %w[--agent --head].each do |flag|
      assert script.include?("opts.on(\"#{flag} "), "bin/merge-permit must take #{flag}"
    end
    assert_includes cycle, 'opts.on("--head SHA"', "bin/devops-cycle must take --head on a scout report"
    assert File.executable?(Rails.root.join("bin", "merge-permit")), "bin/merge-permit must be executable"
  end

  test "[docs] the subagent definition no longer forbids the merge and is installable from the role page" do
    agent = norm("agents/xan/claude-agent.md")

    refute_match(/you do not merge, deploy, or move tasks/i, agent)
    assert_match(/Merge only on its exit 0/, agent)
    assert_match(/When the permit refuses: do not merge/, agent)
    assert_includes norm("agents/xan/role.md"), "docs/agents/agents/xan/claude-agent.md /Users/alex/.claude/agents/xan.md"
  end
end
