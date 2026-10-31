require "test_helper"

# [unit] TeamsConversation's statuses match the CHECK its table was created with
# (20261031120100), and remember! upserts one row per conversation id.
class TeamsConversationTest < ActiveSupport::TestCase
  CONV = "19:general@thread.tacv2".freeze

  test "[unit] the status CHECK lists exactly TeamsConversation::STATUSES" do
    sql = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'teams_conversations_status_known'
    SQL
    assert_equal TeamsConversation::STATUSES.sort, sql.to_s.scan(/'([a-z_]+)'/).flatten.sort
  end

  test "[unit] remember! upserts by conversation id, refreshes serviceUrl and keeps fields an activity left out" do
    first = TeamsConversation.remember!(conversation_id: CONV, service_url: "https://smba.trafficmanager.net/amer/",
                                        team_id: "19:team@thread.tacv2", team_name: "McRitchie Studio", tenant_id: "t1")
    again = TeamsConversation.remember!(conversation_id: CONV, service_url: "https://smba.trafficmanager.net/emea/",
                                        team_name: nil)

    assert_equal first.id, again.id
    assert_equal 1, TeamsConversation.count
    assert_equal "https://smba.trafficmanager.net/emea/", again.service_url
    assert_equal "McRitchie Studio", again.team_name
    assert again.installed?

    removed = TeamsConversation.remember!(conversation_id: CONV, service_url: again.service_url, status: "removed")
    refute removed.installed?
    assert_empty TeamsConversation.installed
  end
end
