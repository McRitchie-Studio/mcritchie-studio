require "test_helper"

class AgentFileLinksTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  setup do
    Agent.find_or_create_by!(slug: "avi") do |agent|
      agent.name = "Avi"
      agent.title = "Product Owner"
      agent.status = "active"
      agent.agent_type = "product"
    end

    Agent.find_or_create_by!(slug: "alex") do |agent|
      agent.name = "Alex"
      agent.title = "Lead Orchestrator"
      agent.status = "active"
      agent.agent_type = "orchestrator"
    end

    Agent.find_or_create_by!(slug: "steffon") do |agent|
      agent.name = "Steffon"
      agent.title = "Platform Engineer"
      agent.status = "active"
      agent.agent_type = "specialist"
    end

    Agent.find_or_create_by!(slug: "turf-monster") do |agent|
      agent.name = "Turf Monster"
      agent.title = "Sports Domain Specialist"
      agent.status = "active"
      agent.agent_type = "specialist"
    end
  end

  # The index is a compact table (task pending-agents-page): each row counts the
  # agent's doc files and links to its own page, where the file tree lists them.
  # The per-file links are asserted on the agent page below.
  test "agent index counts each agent's markdown files and links to its file tree" do
    get agents_path
    assert_response :success

    { "avi" => "avi", "alex" => "alex", "steffon" => "steffon",
      "turf-monster" => "turf_monster" }.each do |slug, dir|
      count = Dir[Rails.root.join("docs", "agents", "agents", dir, "**", "*.md")].size
      assert_operator count, :>, 0, "#{dir} has docs"
      assert_select "[data-test='agent-row'][data-agent='#{slug}']" do
        assert_select "[data-test='agent-docs-link'][data-count='#{count}'][href=?]",
                      agent_path(slug, anchor: "agent-files"), text: "#{count} files"
      end
    end
  end

  test "the agent page's file tree is the index link's target" do
    get agent_path("avi")
    assert_select "#agent-files[data-test='agent-file-tree'][data-agent='avi']" do
      assert_select "[data-test='agent-file-tree-link'][data-path='agents/avi/sops/qa-release.md'][href=?]",
                    doc_path("agents/avi/sops/qa-release.md")
    end
  end

  test "markdown file URLs render through the docs viewer" do
    get doc_path("agents/steffon/HEARTBEAT.md")
    assert_response :success

    assert_select ".prose-themed h1", text: "Steffon Heartbeat"

    get doc_path("agents/avi/sops/qa-release.md")
    assert_response :success

    assert_select ".prose-themed h1", text: "QA Release"

    get doc_path("agents/steffon/sops/production-deploy.md")
    assert_response :success

    assert_select ".prose-themed h1", text: "Production Deploy"

    get doc_path("agents/mason/sops/full-cycle.md")
    assert_response :success

    assert_select ".prose-themed h1", text: "Full Cycle"
  end

  test "agent show renders the agent docs file tree" do
    get agent_path("steffon")
    assert_response :success

    assert_select "[data-test='agent-file-tree'][data-agent='steffon']" do
      assert_select "[data-test='agent-file-tree-node'][data-path='sops'][data-kind='directory']",
                    text: /sops/
      assert_select "[data-test='agent-file-tree-link'][data-path='agents/steffon/HEARTBEAT.md'][href=?]",
                    doc_path("agents/steffon/HEARTBEAT.md"),
                    text: "HEARTBEAT.md"
      assert_select "[data-test='agent-file-tree-link'][data-path='agents/steffon/sops/archive-shipped.md'][href=?]",
                    doc_path("agents/steffon/sops/archive-shipped.md"),
                    text: "archive-shipped.md"
      assert_select "[data-test='agent-file-tree-link'][data-path='agents/steffon/sops/production-deploy.md'][href=?]",
                    doc_path("agents/steffon/sops/production-deploy.md"),
                    text: "production-deploy.md"
      # The tree used to carry an avatar.png node here, asserted present-but-unlinked.
      # Those ten files (5.75MB across every worktree) were retired in
      # serve-or-retire-doc-avatars: the docs route serves `<path>.md` and nothing else,
      # so the nine role.md embeds pointing at them had always rendered broken. The
      # unlinked branch in agents/show.html.erb is still exercised — by the `sops`
      # directory node above — and the invariant that put it there is now guarded
      # directly by test/integration/doc_reference_servability_test.rb.
    end
  end
end
