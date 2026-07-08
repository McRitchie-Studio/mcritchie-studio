require "test_helper"

# [component] the /agents/activities "Filter by session" panel partial. Each session is a
# server-rendered toggle link showing its mascot face, short id, and activity count — plus
# (the polish) a COMPACT last-active time so the newest-first order is legible at a glance.
# The panel itself renders sessions in whatever order the feed concern hands it; ordering
# logic is proven in the integration test.
class AgentsActivitiesFilterTest < ActionView::TestCase
  def session(id:, name:, count: 0, last_at: nil, **attrs)
    { id: id, short: id.first(8), name: name, sprite_url: nil, shiny: false,
      type_color: nil, count: count, last_at: last_at, selected: false }.merge(attrs)
  end

  def render_filter(sessions, active_ids: [])
    render partial: "agents/activities_filter", locals: { sessions: sessions, active_ids: active_ids }
  end

  test "[component] each session row renders a compact last-active time" do
    render_filter [session(id: "sess-fresh", name: "Pikachu", count: 3, last_at: 2.minutes.ago)]

    assert_select "[data-test=aa-fs-ago]", text: "2m ago"
  end

  test "[component] a session with no timestamp renders no recency label" do
    render_filter [session(id: "sess-null", name: "Ditto", count: 0, last_at: nil)]

    assert_select "[data-test=aa-fs-ago]", false
  end

  test "[component] the panel renders sessions in the given most-recent-first order" do
    render_filter [
      session(id: "sess-newer", name: "Newer", last_at: 1.minute.ago),
      session(id: "sess-older", name: "Older", last_at: 1.hour.ago)
    ]

    body = rendered
    assert_operator body.index("sess-newer"), :<, body.index("sess-older")
    assert_operator body.index("1m ago"), :<, body.index("1h ago")
  end

  # ── [component] the live session-name search box (people/teams idiom) ─────

  test "[component] the panel renders a debounced session-name search input" do
    render_filter [session(id: "sess-a", name: "Pikachu", last_at: 1.minute.ago)]

    assert_select "input[type=search][data-test=aa-fs-search]"
    assert_includes rendered, 'x-model.debounce.300ms="sessionQuery"'
  end

  test "[component] the search input is omitted when there are no sessions" do
    render_filter []

    assert_select "[data-test=aa-fs-search]", false
    assert_select ".aa-filter-empty", text: /No sessions captured yet/
  end

  test "[component] each session row carries a lowercased data-name for the client filter" do
    render_filter [session(id: "sess-a", name: "PikaChu", last_at: 1.minute.ago)]

    # the filteredSessions getter matches the typed query against this lowercased name
    assert_select "a[data-test=aa-filter-session][data-name=pikachu]"
  end

  test "[component] the header count binds to the reactive filteredSessions getter" do
    render_filter [
      session(id: "sess-a", name: "Pikachu", last_at: 1.minute.ago),
      session(id: "sess-b", name: "Ditto", last_at: 1.hour.ago)
    ]

    # server-rendered fallback is the total; Alpine swaps in the live filtered count
    assert_select "[x-text=filteredSessions]", text: "2"
  end
end
