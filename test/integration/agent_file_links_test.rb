require "test_helper"

class AgentFileLinksTest < ActionDispatch::IntegrationTest
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

  test "agent index links to each agent markdown file" do
    get agents_path
    assert_response :success

    assert_select "[data-test='agent-card'][data-agent='avi']" do
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/HEARTBEAT.md'][href=?]",
                    doc_path("agents/avi/HEARTBEAT.md"),
                    text: "HEARTBEAT.md"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/soul.md'][href=?]",
                    doc_path("agents/avi/soul.md"),
                    text: "soul.md"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/role.md'][href=?]",
                    doc_path("agents/avi/role.md"),
                    text: "role.md"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/avatar.png']", count: 0
    end

    assert_select "[data-test='agent-card'][data-agent='alex']" do
      assert_select "[data-test='agent-file-link'][data-file='agents/alex/HEARTBEAT.md'][href=?]",
                    doc_path("agents/alex/HEARTBEAT.md"),
                    text: "HEARTBEAT.md"
    end

    assert_select "[data-test='agent-card'][data-agent='steffon']" do
      assert_select "[data-test='agent-file-link'][data-file='agents/steffon/HEARTBEAT.md'][href=?]",
                    doc_path("agents/steffon/HEARTBEAT.md"),
                    text: "HEARTBEAT.md"
    end

    assert_select "[data-test='agent-card'][data-agent='turf-monster']" do
      assert_select "[data-test='agent-file-link'][data-file='agents/turf_monster/soul.md'][href=?]",
                    doc_path("agents/turf_monster/soul.md"),
                    text: "soul.md"
      assert_select "[data-test='agent-file-link'][data-file='agents/turf_monster/role.md'][href=?]",
                    doc_path("agents/turf_monster/role.md"),
                    text: "role.md"
    end
  end

  test "markdown file URLs render through the docs viewer" do
    get doc_path("agents/steffon/HEARTBEAT.md")
    assert_response :success

    assert_select ".prose-themed h1", text: "Steffon Heartbeat"
  end
end
