require "test_helper"

# [component] the /agents/activities live subscription chooses the websocket scope
# from the current session filter. Unfiltered pages keep the global feed; filtered pages
# subscribe only to the selected session streams so unrelated activity stays off-screen.
class AgentsActivitiesLiveStreamsTest < ActionView::TestCase
  def render_streams(session_ids)
    render partial: "agents/activities_live_streams", locals: { session_ids: session_ids }
  end

  test "[component] no filters subscribes to the global activities stream" do
    render_streams []

    assert_select "turbo-cable-stream-source", 1
    assert_includes rendered, Turbo::StreamsChannel.signed_stream_name("agents_activities")
  end

  test "[component] selected filters subscribe only to matching session streams" do
    render_streams ["sess-A", "sess-B"]

    assert_select "turbo-cable-stream-source", 2
    assert_includes rendered, Turbo::StreamsChannel.signed_stream_name("agents_activities:session:sess-A")
    assert_includes rendered, Turbo::StreamsChannel.signed_stream_name("agents_activities:session:sess-B")
    refute_includes rendered, Turbo::StreamsChannel.signed_stream_name("agents_activities")
  end
end
