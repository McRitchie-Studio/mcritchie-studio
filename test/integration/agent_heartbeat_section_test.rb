require "test_helper"

# [component][integration] The HEARTBEAT section on the agent profile page
# (agents/show). Souls that own a heartbeat (Carl / Avi / Steffon / Alex / Turf
# Monster — the entries in ApplicationHelper#heartbeat_launchers) get a section listing their
# heartbeat name plus each launcher act as a copyable phrase + a one-line
# description. Agents that do NOT own a heartbeat (Shannon / Jasper) render no
# section at all.
#
# Assertions read the SERVER-RENDERED data-clip + visible text (Nokogiri can't see
# Alpine-toggled state), matching the copy-launcher convention on /deployments.
class AgentHeartbeatSectionTest < ActionDispatch::IntegrationTest
  # Create the souls this spec visits locally (transactional fixtures roll them
  # back). NOT global fixtures — other suites create avi/carl/shannon agents in
  # their own setup, so a shared fixture would collide on the unique slug.
  setup do
    Agent.find_or_create_by!(slug: "carl") { |a| a.name = "Carl" }
    Agent.find_or_create_by!(slug: "avi")  { |a| a.name = "Avi" }
    Agent.find_or_create_by!(slug: "alex") { |a| a.name = "Alex" }
    Agent.find_or_create_by!(slug: "steffon") { |a| a.name = "Steffon" }
    Agent.find_or_create_by!(slug: "shannon") { |a| a.name = "Shannon" }
    # The name must parameterize BACK to the slug — Agent includes Sluggable, which
    # re-derives the slug on save, so "Turf Monster" -> "turf-monster" round-trips.
    Agent.find_or_create_by!(slug: "turf-monster") { |a| a.name = "Turf Monster" }
  end

  test "Carl's heartbeat soul renders the review acts + descriptions" do
    get agent_path("carl")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='carl']", count: 1
    assert_select "[data-test='heartbeat-name'][data-clip='Carl Heartbeat']"
    assert_select "[data-test='heartbeat-name'] code", text: "Carl Heartbeat"

    assert_select "[data-test='action']", count: 2
    assert_select "[data-test='action'][data-action='pr-review'][data-clip='pr-review']"
    assert_select "[data-test='action'][data-action='pr-review-slow'][data-clip='pr-review-slow']"
    # review-only contract: the pr-review caption must not claim the merge to
    # release — that belongs to Avi's sweep (phrasing mirrors heartbeats.md).
    assert_match "Review all submitted PRs (review-only — Avi sweeps)", response.body
    assert_match "Review submitted PRs one at a time", response.body
  end

  test "a heartbeat soul's page renders the section with each act + description" do
    get agent_path("avi")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='avi']", count: 1
    # The soul heartbeat name is present and copyable (server-rendered data-clip).
    assert_select "[data-test='heartbeat-name'][data-clip='Avi Heartbeat']"
    assert_select "[data-test='heartbeat-name'] code", text: "Avi Heartbeat"

    # All of Avi's acts render as copyable phrases with their captions.
    assert_select "[data-test='action']", count: 2
    assert_select "[data-test='action'][data-action='qa-release'][data-clip='qa-release']"
    assert_select "[data-test='action'][data-action='deploy-with-task'][data-clip='deploy-with-task']"
    assert_match "Prepare + deploy the QA release", response.body
    # deploy-with-task is interactive — its caption carries the "what task?" ask.
    assert_match "Expedite ONE task to prod (asks: what task?)", response.body
  end

  test "Alex's heartbeat soul renders its acts + descriptions" do
    get agent_path("alex")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='alex']", count: 1
    assert_select "[data-test='heartbeat-name'][data-clip='Alex Heartbeat']"
    assert_select "[data-test='action']", count: 3
    assert_select "[data-test='action'][data-action='grade-events'][data-clip='grade-events']"
    assert_select "[data-test='action'][data-action='share-insights'][data-clip='share-insights']"
    assert_select "[data-test='action'][data-action='full-cycle'][data-clip='full-cycle']"
    assert_match "Grade 10 recent events for quality", response.body
    assert_match "Share confirmed insights into the docs", response.body
  end

  test "Steffon's heartbeat soul renders the ship + sweep acts" do
    get agent_path("steffon")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='steffon']", count: 1
    assert_select "[data-test='heartbeat-name'][data-clip='Steffon Heartbeat']"
    assert_select "[data-test='action']", count: 2
    assert_select "[data-test='action'][data-action='production-deploy'][data-clip='production-deploy']"
    assert_select "[data-test='action'][data-action='clean-infra'][data-clip='clean-infra']"
    assert_match "Ship a QA-ready release to production", response.body
    assert_match "Sweep this machine", response.body
    # archive-shipped left the launcher when production-deploy took over running it.
    # It is still a registered SOP — this asserts the LAUNCHER contract only.
    assert_select "[data-test='action'][data-action='archive-shipped']", count: 0
  end

  test "Turf Monster is a heartbeat soul and renders the live score watch act" do
    get agent_path("turf-monster")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section'][data-agent='turf-monster']", count: 1
    assert_select "[data-test='heartbeat-name'][data-clip='Turf Monster Heartbeat']"
    assert_select "[data-test='heartbeat-name'] code", text: "Turf Monster Heartbeat"
    # One act — the watch occupies the session for a whole game window, so there is
    # deliberately nothing behind it to starve.
    assert_select "[data-test='action']", count: 1
    assert_select "[data-test='action'][data-action='live-score-watch'][data-clip='live-score-watch']"
    assert_match "Watch a live NFL slot", response.body
  end

  test "a non-heartbeat agent's page renders no heartbeat section" do
    get agent_path("shannon")
    assert_response :success

    assert_select "[data-test='agent-heartbeat-section']", count: 0
    assert_select "[data-test='heartbeat-name']", count: 0
    assert_select "[data-test='action']", count: 0
    # The rest of the profile still renders as before.
    assert_select "h3", text: "Skills"
  end
end
