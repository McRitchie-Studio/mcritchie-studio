require "test_helper"

# [unit] Broadcasts::CyvassePlayTimes picks the play-times note's subject from
# the reader's merge fields (task cyvasse-play-times-email).
class Broadcasts::CyvassePlayTimesTest < ActiveSupport::TestCase
  test "a reader with a username gets the personal line" do
    assert_equal Broadcasts::CyvassePlayTimes::PERSONAL_SUBJECT,
                 Broadcasts::CyvassePlayTimes.subject_template({ "username" => "veyjin" })
  end

  test "a reader without a username gets the plain line" do
    assert_equal Broadcasts::CyvassePlayTimes::PLAIN_SUBJECT, Broadcasts::CyvassePlayTimes.subject_template({})
    assert_equal Broadcasts::CyvassePlayTimes::PLAIN_SUBJECT, Broadcasts::CyvassePlayTimes.subject_template({ "username" => "" })
    assert_equal Broadcasts::CyvassePlayTimes::PLAIN_SUBJECT, Broadcasts::CyvassePlayTimes.subject_template(nil)
  end

  test "Broadcast#subject_for fills the username through the registered resolver" do
    broadcast = Broadcast.new(template_key: "cyvasse_play_times", subject: "Stored subject is ignored")
    assert_equal "veyjin, how was your first game on the new Cyvasse?", broadcast.subject_for({ "username" => "veyjin" })
    assert_equal "How was your first game on the new Cyvasse?", broadcast.subject_for({})
  end
end
