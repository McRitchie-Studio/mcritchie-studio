require "test_helper"

# [integration] Hank, the Commercial Welding business agent (renamed from Dawn),
# is seeded from config/souls.yml and the agents page draws his badger portrait
# and links his soul doc. The avatar is DATA, so a wrong path would 404 and
# _agent_avatar's onerror would silently fall back to initials.
class HankAgentCardTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex))
    capture_io { load Rails.root.join("db/seeds/02_agents.rb").to_s }
  end

  test "the agents page renders the Hank row with his badger portrait" do
    get agents_path
    assert_response :success

    assert_select "[data-test='agent-row'][data-agent='hank']" do
      assert_select "img[src='/agents/hank.webp'][alt='Hank']"
      assert_select "[data-test='agent-docs-link'][href=?]", agent_path("hank", anchor: "agent-files"), text: "1 file"
    end
    assert_select "[data-test='agent-row'][data-agent='dawn']", count: 0
    assert Rails.public_path.join("agents/hank.webp").exist?
  end
end
