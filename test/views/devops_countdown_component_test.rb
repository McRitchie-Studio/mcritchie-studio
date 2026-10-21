require "test_helper"

# [component] The live pill's countdown (agent_chats/_devops_stages; task
# live-build-countdown): a step with a real start carries its expected finish as
# data-deadline and paints the clock to it (MM:SS, H:MM:SS from an hour up) for
# devops_countdown.js to tick; past it the pill reads Any minute now. The ticking
# span is hidden from screen readers, which hear the rounded ETA once. A wait with
# no real start (Prepping, no builder) keeps its words, with no countdown.
class DevopsCountdownComponentTest < ActionView::TestCase
  Eta = AppDevopsStages::Eta

  def app = @app ||= App.new(slug: "countdown-probe", name: "Countdown Probe")

  def board_with(eta, label: "Building", prepping: false)
    stages = AppDevopsStages::STAGES.map do |key, name|
      live = key == "building"
      AppDevopsStages::Stage.new(key: key, label: live ? label : name, state: live ? :live : :pending, count: live ? 1 : 0,
                                 sub_label: (live && !prepping ? "Building" : nil), eta: (eta if live), prepping: prepping)
    end
    item = AppDevopsStages::Item.new(title: "Launching Countdown Probe", lane: "Building", at: Time.current, sub_label: "Building", eta: eta)
    AppDevopsStages::Board.new(stages: stages, items: [ item ], total: 1)
  end

  def render_board(board) = render(partial: "agent_chats/devops_stages", locals: { app: app, board: board })

  def pill = "[data-test='devops-stage'][data-stage='building']"

  test "[component] a live step renders its deadline and the MM:SS fallback in tabular numerals, hidden from screen readers" do
    freeze_time do
      started = Time.current - 12.seconds
      render_board(board_with(Eta.estimate("building", entered_at: started, medians: { "building" => 360 }, launcher: false)))

      eta = css_select("#{pill} [data-test='devops-stage-eta']").sole
      assert_equal (started + 360).utc.iso8601, eta["data-deadline"]
      assert eta.key?("data-devops-countdown"), "the ticker's hook"
      assert_equal "05:48", eta.text
      assert_equal "left", eta["data-eta-kind"]
      assert_includes eta["class"].split, "tabular-nums", "the digits hold still as they tick"
      assert_equal "true", eta["aria-hidden"], "a screen reader never hears each tick"
      assert_select "#{pill} .sr-only", text: /~6 min left/, count: 1
      assert_select "[data-test='devops-task-status']", { text: "Building · ~6 min left" }, "the row keeps the rounded words"
    end
  end

  test "[component] an hour or more reads H:MM:SS" do
    freeze_time do
      render_board(board_with(Eta.estimate("submitted", entered_at: Time.current - 3.minutes, medians: { "submitted" => 3723 + 180 }, launcher: false)))
      assert_select "#{pill} [data-test='devops-stage-eta']", text: "1:02:03"
    end
  end

  test "[component] past the deadline the pill reads Any minute now, never a negative" do
    freeze_time do
      render_board(board_with(Eta.estimate("building", entered_at: Time.current - 10.minutes, medians: { "building" => 360 }, launcher: false)))
      eta = css_select("#{pill} [data-test='devops-stage-eta']").sole
      assert_equal [ "Any minute now", "long" ], [ eta.text, eta["data-eta-kind"] ]
      assert eta["data-deadline"].present?, "still a deadline, so the ticker keeps it at Any minute now"
      assert_select "[data-test='devops-task-status']", text: "Building · taking longer than usual"
    end
  end

  test "[component] Prepping with a live launcher keeps its rounded wait, with no countdown" do
    render_board(board_with(Eta.estimate("designed", entered_at: 1.minute.ago, medians: { "designed" => 1200 }, launcher: true),
                            label: "Prepping", prepping: true))
    assert_select "#{pill} [data-test='devops-stage-eta']", text: "~20 min"
    assert_select "[data-devops-countdown]", 0
    assert_select "[data-deadline]", 0
  end

  test "[component] no builder keeps its words, with no countdown" do
    render_board(board_with(Eta::WAITING))
    assert_select "#{pill} [data-test='devops-stage-eta']", text: "no builder"
    assert_select "[data-devops-countdown]", 0
  end

  test "[component] the ticker is pinned and loaded on every page, and the server's clock matches the browser's" do
    assert_match(/^pin "devops_countdown"$/, Rails.root.join("config/importmap.rb").read)
    assert_match(/^import "devops_countdown"$/, Rails.root.join("app/javascript/application.js").read)
    js = Rails.root.join("app/javascript/devops_countdown.js").read
    assert_includes js, %(export const ANY_MINUTE = "#{Eta::ANY_MINUTE}";), "the two clocks say the same past zero"
  end
end
