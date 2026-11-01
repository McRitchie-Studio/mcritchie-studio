require "test_helper"

# [unit] The four-style scoreboard: ranked by matches played, and honest about
# when a lead means nothing yet.
class Broadcasts::CyvasseFourScoreboardTest < ActiveSupport::TestCase
  setup do
    @drafts = Broadcasts::CyvasseFour::STYLES.to_h do |style, (key, _)|
      [ style, Broadcast.create!(slug: "cyvasse-four-#{style}", subject: style, template_key: key) ]
    end
    @n = 0
  end

  def send_to(style, count, played: 0, clicked: 0)
    count.times.map do |i|
      @n += 1
      contact = Contact.create!(email: "reader#{@n}@example.com")
      delivery = BroadcastDelivery.create!(broadcast: @drafts.fetch(style), contact: contact, sent_at: 1.hour.ago, delivered_at: 1.hour.ago)
      delivery.record_click!(link_key: "play") if i < clicked
      delivery.record_event!(kind: "converted", source: "beacon", data: { "goal" => "played_match" }) if i < played
      delivery
    end
  end

  def board = Broadcasts::CyvasseFourScoreboard.new

  test "with nothing sent it says so" do
    assert_equal :waiting, board.verdict.state
    assert_nil board.verdict.leader
  end

  test "styles rank by the share who played, not the raw count" do
    send_to("poster", 40, played: 4)
    send_to("dragon", 10, played: 2)
    assert_equal "dragon", board.rows.first.style
  end

  test "a small sample is too early, whatever the gap" do
    Broadcasts::CyvasseFour::STYLES.each_key { |style| send_to(style, 5, played: style == "pick" ? 4 : 0) }
    assert_equal :early, board.verdict.state
    assert_equal "pick", board.verdict.leader.style
  end

  test "a style not yet sent keeps it early" do
    %w[poster pick wrapped].each { |style| send_to(style, 100, played: 30) }
    assert_equal :early, board.verdict.state
  end

  test "the lead is judged on clicks until anyone plays" do
    send_to("poster", 5, clicked: 2)
    assert_equal "clicked", board.verdict.metric
  end

  test "a wide gap at full sample is clear" do
    send_to("poster", 100, played: 30)
    %w[pick wrapped dragon].each { |style| send_to(style, 100, played: 5) }
    assert_equal :clear, board.verdict.state
    assert_equal "poster", board.verdict.leader.style
  end

  test "a narrow gap at full sample is close" do
    send_to("poster", 100, played: 30)
    send_to("pick", 100, played: 28)
    %w[wrapped dragon].each { |style| send_to(style, 100, played: 5) }
    assert_equal :close, board.verdict.state
  end

  test "a machine click is not a click" do
    send_to("poster", 1).first.record_click!(link_key: "play", machine: true)
    assert_equal 0, board.rows.find { |row| row.style == "poster" }.clicked
  end

  test "The Pick's answers count people per tracked link" do
    send_to("pick", 1).first.record_click!(link_key: "elephant")
    assert_equal [ "The Elephant", 1 ], board.pick_answers.first
  end
end
