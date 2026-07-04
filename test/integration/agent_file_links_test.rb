require "test_helper"

class AgentFileLinksTest < ActionDispatch::IntegrationTest
  setup do
    Agent.find_or_create_by!(slug: "avi") do |agent|
      agent.name = "Avi"
      agent.title = "Product Owner"
      agent.status = "active"
      agent.agent_type = "product"
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
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/HEARTBEAT'][href=?]",
                    doc_path("agents/avi/HEARTBEAT"),
                    text: "Heartbeat"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/soul'][href=?]",
                    doc_path("agents/avi/soul"),
                    text: "Soul"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/role'][href=?]",
                    doc_path("agents/avi/role"),
                    text: "Role"
      assert_select "[data-test='agent-file-link'][data-file='agents/avi/avatar']", count: 0
    end

    assert_select "[data-test='agent-card'][data-agent='turf-monster']" do
      assert_select "[data-test='agent-file-link'][data-file='agents/turf_monster/soul'][href=?]",
                    doc_path("agents/turf_monster/soul"),
                    text: "Soul"
      assert_select "[data-test='agent-file-link'][data-file='agents/turf_monster/role'][href=?]",
                    doc_path("agents/turf_monster/role"),
                    text: "Role"
    end
  end
end
