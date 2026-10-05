require "test_helper"
require "rake"

# [integration] contacts:tag_new_stack_players (task first-game-feedback-survey):
# tags the contacts who played the rebuilt Cyvasse, from the cyvasse CSV and
# from the hub's played_match email results, stores the first-game date in
# traits["cyvasse"] without touching the rest, skips Alex, and prints counts only.
class TagNewStackPlayersTaskTest < ActiveSupport::TestCase
  TASK = "contacts:tag_new_stack_players".freeze
  TAG = Contacts::NewStackPlayerTagger::TAG

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    Rake::Task[TASK].reenable
    @vey = Contact.create!(email: "vey@example.com", tags: %w[cyvasse-legacy],
                           traits: { "cyvasse" => { "username" => "veyjin", "games" => 27 }, "turf" => { "x" => 1 } })
    @guest = Contact.create!(email: "guest@example.com", tags: %w[newsletter])
    @alex = Contact.create!(email: "amcritchie@gmail.com")
    @studio = Contact.create!(email: "alex@mcritchie.studio")
    @bystander = Contact.create!(email: "never@example.com", tags: %w[cyvasse-legacy])
    @file = csv("Vey@example.com,2026-09-29,4", "AMcritchie@gmail.com,2026-09-28,9", "nobody@example.com,2026-09-30,1",
                "broken,not-a-date,1")
  end

  teardown { @file.close! }

  def csv(*rows)
    Tempfile.new([ "new-stack", ".csv" ]).tap do |f|
      f.write("#{Contacts::NewStackPlayerTagger::HEADERS.join(",")}\n#{rows.join("\n")}\n")
      f.flush
    end
  end

  def played_match(contact, at)
    broadcast = Broadcast.find_or_create_by!(slug: "tag-test") { |b| b.assign_attributes(subject: "s", template_key: "cyvasse_is_back") }
    delivery = broadcast.deliveries.create!(contact:, sent_at: at - 1.hour)
    delivery.events.create!(kind: "converted", source: "beacon", occurred_at: at, data: { "goal" => "played_match" })
  end

  def run_task(path = @file.path)
    Rake::Task[TASK].reenable
    capture_io { Rake::Task[TASK].invoke(*path) }.first
  end

  test "tags CSV players and played_match contacts, merges the date into traits, prints counts only" do
    played_match(@guest, Time.utc(2026, 10, 1, 18))
    played_match(@studio, Time.utc(2026, 10, 1, 18))
    out = run_task

    assert_includes @vey.reload.tags, TAG
    assert_includes @vey.tags, "cyvasse-legacy"
    assert_equal({ "username" => "veyjin", "games" => 27, "first_new_game_on" => "2026-09-29", "new_games" => 4 },
                 @vey.traits["cyvasse"])
    assert_equal({ "x" => 1 }, @vey.traits["turf"])

    assert_includes @guest.reload.tags, TAG
    assert_equal({ "first_new_game_on" => "2026-10-01" }, @guest.traits["cyvasse"])

    [ @alex, @studio, @bystander ].each { |c| assert_not_includes c.reload.tags, TAG, c.email }
    assert_match(/4 csv rows \(1 invalid\), 2 played_match contacts; 2 excluded, 1 without a contact; 2 matched: 2 newly tagged/, out)
    assert_match(/#{TAG} now: 2 contacts/, out)
    assert_no_match(/vey|guest|nobody|amcritchie|alex@/i, out)
  end

  test "the earliest first-game date wins across sources, and a re-run changes nothing" do
    played_match(@vey, Time.utc(2026, 9, 28, 20))
    run_task
    assert_equal "2026-09-28", @vey.reload.cyvasse["first_new_game_on"]
    assert_equal 4, @vey.cyvasse["new_games"]

    stamp = @vey.updated_at
    out = run_task
    assert_match(/0 newly tagged, 0 updated, 1 unchanged/, out)
    assert_equal stamp, @vey.reload.updated_at
  end

  test "without a CSV it tags from the email results alone" do
    played_match(@guest, Time.utc(2026, 10, 2))
    out = run_task(nil)
    assert_includes @guest.reload.tags, TAG
    assert_not_includes @vey.reload.tags, TAG
    assert_match(/0 csv rows/, out)
  end

  test "a later traits import keeps the first-game date" do
    run_task
    traits = Tempfile.new([ "traits", ".csv" ])
    traits.write("#{Contacts::CyvasseTraitsImport::HEADERS.join(",")}\n" \
                 "vey@example.com,veyjin,30,28,22,8,2014-03-02,2026-10-01,10,2026-10-02T12:00:00Z\n")
    traits.flush
    File.open(traits.path) { |io| Contacts::CyvasseTraitsImport.new(io).run }
    assert_equal 30, @vey.reload.cyvasse["games"]
    assert_equal "2026-09-29", @vey.cyvasse["first_new_game_on"]
    assert_equal 4, @vey.cyvasse["new_games"]
  ensure
    traits&.close!
  end
end
