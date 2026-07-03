require "test_helper"

# [component][integration] The HEARTBEAT section on the agent profile page
# (agents/show). Souls that own a heartbeat (Avi / Steffon / Alex — the entries in
# ApplicationHelper#heartbeat_launchers) get a section listing their heartbeat name
# plus each launcher act as a copyable phrase + a one-line description. Agents that
# do NOT own a heartbeat (Carl / Shannon / Jasper) render no section at all.
#
# Assertions read the SERVER-RENDERED data-clip + visible text (Nokogiri can't see
# Alpine-toggled state), matching the copy-launcher convention on /deployments.
class AgentHeartbeatSectionTest < ActionDispatch::IntegrationTest
  # Create the souls this spec visits locally (transactional fixtures roll them
  # back). NOT global fixtures — other suites create avi/carl/shannon agents in
  # their own setup, so a shared fixture would collide on the unique slug.
  setup do
    Agent.find_or_create_by!(slug: "avi")  { |a| a.name = "Avi" }
    Agent.find_or_create_by!(slug: "alex") { |a| a.name = "Alex" }
    Agent.find_or_create_by!(slug: "carl") { |a| a.name = "Carl" }
  end

  test "a heartbeat soul's page renders the section with each act + description" do
    get agent_path("avi")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='avi']", count: 1
    # The soul heartbeat name is present and copyable (server-rendered data-clip).
    assert_select "[data-test='heartbeat-name'][data-clip='Avi Heartbeat']"
    assert_select "[data-test='heartbeat-name'] code", text: "Avi Heartbeat"

    # Both of Avi's acts render as copyable phrases with their captions.
    assert_select "[data-test='action']", count: 3
    assert_select "[data-test='action'][data-action='pr-review'][data-clip='pr-review']"
    assert_select "[data-test='action'][data-action='production-deploy'][data-clip='production-deploy']"
    assert_select "[data-test='action'][data-action='pr-review-slow'][data-clip='pr-review-slow']"
    assert_match "Review + merge all submitted PRs", response.body
    assert_match "Ship a QA-ready release to production", response.body
  end

  test "a single-act heartbeat soul (Alex) renders its one act + description" do
    get agent_path("alex")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='alex']", count: 1
    assert_select "[data-test='heartbeat-name'][data-clip='Alex Heartbeat']"
    assert_select "[data-test='action']", count: 2
    assert_select "[data-test='action'][data-action='grade-events'][data-clip='grade-events']"
    assert_select "[data-test='action'][data-action='full-cycle'][data-clip='full-cycle']"
    assert_match "Grade 10 recent events for quality", response.body
  end

  test "a non-heartbeat agent's page renders no heartbeat section" do
    get agent_path("carl")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section']", count: 0
    assert_select "[data-test='heartbeat-name']", count: 0
    assert_select "[data-test='action']", count: 0
    # The rest of the profile still renders as before.
    assert_select "h3", text: "Skills"
  end
end
