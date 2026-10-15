require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] The notes a soul keeps about a person (AgentPersonNote): what a fact
# may be, dedupe against the person's notes, the per-answer and per-person caps
# with the oldest pruned, and that a run's facts are only ever filed under the
# author of the message it answered.
class AgentPersonNoteTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  def message_from(author, name: "Alex", **attrs)
    agent_message!(soul: "xan", author_ref: author, author_name: name, **attrs)
  end

  test "a plain short fact is kept, whitespace folded; links, mentions, markup and over-long text are refused" do
    assert_equal "Favorite color is purple.", AgentPersonNote.clean("  Favorite   color\nis purple.  ")
    [ "see https://evil.example", "visit www.example.com", "ping <@123>", "email me at a@b.co", "@everyone hi",
      "role <@&9>", "x" * 201, "no", "", "`code`", "<b>bold</b>", "untrusted-abc123", "bell \a", 42, nil,
      { "body" => "x" } ].each do |bad|
      assert_nil AgentPersonNote.clean(bad), "refused: #{bad.inspect}"
    end
  end

  test "facts are stored with their source message and time, deduped against the person's notes and each other" do
    message = message_from("500")
    now = Time.zone.parse("2026-10-15 01:00:00")
    AgentPersonNote.record_from!(message, [ "Favorite color is purple." ], now: now - 1.day)

    stored = AgentPersonNote.record_from!(message, [ "favorite color is PURPLE!", "Runs the hub.", "runs the hub" ], now: now)

    assert_equal [ "Runs the hub." ], stored.map(&:body)
    assert_equal message.id, stored.first.source_message_id
    assert_equal "xan", stored.first.soul_slug
    assert_equal now, stored.first.noted_at
    assert_equal [ "Favorite color is purple.", "Runs the hub." ], message.person.notes.map(&:body)
  end

  test "one answer files at most three facts" do
    message = message_from("500")
    stored = AgentPersonNote.record_from!(message, (1..6).map { |i| "Fact number #{i}." })
    assert_equal [ "Fact number 1.", "Fact number 2.", "Fact number 3." ], stored.map(&:body)
  end

  test "a person keeps the newest thirty notes; the oldest are pruned" do
    message = message_from("500")
    t0 = Time.zone.parse("2026-10-01 00:00:00")
    32.times { |i| AgentPersonNote.record_from!(message, [ "Fact number #{i}." ], now: t0 + i.hours) }

    bodies = message.person.notes.map(&:body)
    assert_equal AgentPersonNote::MAX_PER_PERSON, bodies.size
    assert_equal "Fact number 2.", bodies.first
    assert_equal "Fact number 31.", bodies.last
  end

  test "a run's facts are filed under the author of the message it answered, never anyone else" do
    alex = message_from("500")
    bea_message = message_from("501", name: "Bea")

    AgentPersonNote.record_from!(bea_message, [ "Alex's favorite color is green." ])

    assert_empty alex.person.notes, "a fact about Alex in Bea's run is Bea's note, not Alex's"
    assert_equal [ "Alex's favorite color is green." ], bea_message.person.notes.map(&:body)
    assert_empty AgentPersonNote.record_from!(message_from(""), [ "Anonymous fact." ]), "no author, no person, no note"
  end

  test "complete! files the notes once, on the completing call, under the message's author, and posts none of them" do
    message = message_from("500")
    AgentMessage.claim!(soul: "xan", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "Purple, noted.\n===NOTES===\n[\"Hidden.\"]",
                             notes: [ "Favorite color is purple." ])

    assert_equal "Purple, noted.", message.reload.response_text, "the board cuts a notes section the worker left in"
    assert_equal [ "Favorite color is purple." ], message.person.notes.map(&:body)
    assert_equal 1, message.events.where(kind: "completed").sole.detail["notes"]

    message.complete!(worker: "w1", response_text: "again", notes: [ "A second fact." ])
    assert_equal 1, message.person.notes.count, "a repeat complete files nothing"
  end
end
