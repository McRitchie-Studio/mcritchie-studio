require "test_helper"

# [component] heartbeat/_nav — the in-context navbar chip cluster shared by the
# per-session heartbeat (show) and the All Spans page. Asserts the back link to
# the Deployments board renders as an hb-btn chip pointing at deployments_path,
# on both surfaces (it lives in the shared cluster, not gated on `current`).
class HeartbeatNavTest < ActionView::TestCase
  test "[component] renders a back link to the deployments board" do
    render partial: "heartbeat/nav", locals: { current: :session, insights_count: 0 }

    link = css_select("a[data-test=hb-nav-deployments]").first
    assert link, "the heartbeat nav must render a Deployments back link"
    assert_equal deployments_path, link["href"]
    assert_includes link["class"].to_s.split, "hb-btn", "the back link is an hb-btn chip"
    assert_match "Deployments", link.text
  end

  test "[component] the deployments back link renders on the All Spans surface too" do
    render partial: "heartbeat/nav", locals: { current: :all_activities, insights_count: 0 }

    assert css_select("a[data-test=hb-nav-deployments]").any?,
           "the Deployments back link must render regardless of the active surface"
  end
end
