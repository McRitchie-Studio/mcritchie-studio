require "test_helper"

# [unit] The four-prong split and subjects (task cyvasse-four-prong-emails).
class Broadcasts::CyvasseFourTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  Four = Broadcasts::CyvasseFour

  def player(email, games, **attrs)
    Contact.create!({ email: email, tags: [ "cyvasse-legacy" ], traits: { "cyvasse" => { "username" => email[/\w+/], "games" => games } } }.merge(attrs))
  end

  def draft!
    Four::STYLES.each do |style, (key, resolver)|
      Broadcast.create!(slug: "#{Four::SLUG_PREFIX}#{style}", template_key: key, subject: resolver.plain, target_list: Four::AUDIENCE)
    end
  end

  def verify!(*contacts)
    contacts.each { |c| c.update!(verification_status: "valid", verified_at: Time.current) }
  end

  test "each style personalises with a username and stays plain without one" do
    Four::STYLES.each_value do |_key, style|
      assert_equal style.personal, style.subject_template({ "username" => "veyjin" })
      assert_equal style.plain, style.subject_template({})
      assert_no_match(/%\{/, style.plain)
    end
  end

  test "deal gives every style the same count and one of each top four" do
    hands = Four.deal((1..403).to_a, random: Random.new(4))
    assert_equal 403, hands.values.flatten.uniq.size
    assert_equal [ 100, 101 ], hands.values.map(&:size).minmax
    assert_equal (1..4).to_a, hands.values.map { |ids| ids.first }.sort
  end

  test "win rate rounds and is nil with no decided game" do
    assert_equal 54, Four.win_rate({ "wins" => 31, "losses" => 26 })
    assert_nil Four.win_rate({ "wins" => 0, "losses" => 0 })
    assert_nil Four.win_rate({})
  end

  test "candidates take most games first and leave out the mailed, the held and the unverified" do
    top = player("top@example.com", 90)
    low = player("low@example.com", 3)
    mailed = player("mailed@example.com", 500)
    held = player("held@example.com", 400)
    unverified = player("unverified@example.com", 300)
    verify!(top, low, mailed, held)
    other = Broadcast.create!(slug: "old-send", template_key: "cyvasse_is_back", subject: "Back")
    other.deliveries.create!(contact: mailed, sent_at: Time.current)
    other.staged_emails.create!(contact: held, status: "staged", staged_at: Time.current)

    assert_equal [ top, low ], Four.candidates.to_a
    assert_not_includes Four.candidates, unverified
  end

  test "stage holds each reader once across the four and sends nothing" do
    draft!
    verify!(*(1..8).map { |i| player("p#{i}@example.com", i) })
    assert_no_enqueued_jobs do
      results = Four.stage!(limit: 8, random: Random.new(1))
      assert_equal [ 2 ], results.values.map(&:staged).uniq
    end
    assert_equal 8, StagedEmail.distinct.count(:contact_id)
    assert_equal [ "staged" ], StagedEmail.distinct.pluck(:status)
    assert_equal({}, Four.stage!(limit: 8).reject { |_style, r| r.total.zero? })
  end
end
