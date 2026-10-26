# frozen_string_literal: true

require "test_helper"
require Rails.root.join("bin/lib/dream_bank").to_s

# [unit] DreamRuling: Alex McRitchie's ruling given in chat, recorded with his quoted words and
# the session that heard them (docs/agents/modules/dream.md, Act 3, "In chat").
class DreamRulingTest < ActiveSupport::TestCase
  WORDS = "Approve that one, it is right"

  setup { users(:alex).update_column(:slug, "alex-mcritchie-test") }

  def dream(slug: "new-habit", home: "carl", status: "proposed")
    DreamBank::Dream.new(slug: slug, home: home, status: status, question: "Q?", answer: "A.", why: "",
                         tags: {}, source: "", story: "")
  end

  def rule(ruling, target = dream, clearance: WORDS, session: "chat-session")
    DreamRuling.record!(ruling: ruling, dream: target, clearance: clearance, session_id: session)
  end

  test "[unit] approve records a chat approval naming Alex McRitchie, with his words and the session" do
    row, created = rule("approve")

    assert created
    assert_kind_of DreamApproval, row
    assert_equal [ "chat", WORDS, "chat-session", "alex-mcritchie-test" ],
                 [ row.via, row.clearance, row.session_id, row.approved_by_slug ]
    assert row.chat?
    assert_nil row.applied_at
  end

  test "[unit] drop records a drop of a proposed dream, retire a retirement of an approved one" do
    dropped, = rule("drop", clearance: "drop number two please")
    retired, = rule("retire", dream(slug: "old-habit", status: "approved"), clearance: "retire the old habit")

    assert_equal [ "drop", "chat" ], [ dropped.ruling, dropped.via ]
    assert dropped.drop?
    assert_equal [ "retire", "chat", "alex-mcritchie-test" ], [ retired.ruling, retired.via, retired.retired_by_slug ]
  end

  test "[unit] a missing, token or slug-only clearance is refused and records nothing" do
    [ "", "ok", "new-habit", "`carl/new-habit`" ].each do |words|
      assert_raises(DreamRuling::Refused, words) { rule("approve", clearance: words) }
    end
    assert_equal 0, DreamApproval.count
  end

  test "[unit] the card grammar's bare yes stands as his clearance" do
    row, = rule("approve", clearance: "yes")
    assert_equal "yes", row.clearance
  end

  test "[unit] a ruling needs the session, a known dream and the right status" do
    assert_match(/session/, assert_raises(DreamRuling::Refused) { rule("approve", session: " ") }.message)
    assert_match(/deployed bank/, assert_raises(DreamRuling::Refused) { rule("approve", nil) }.message)
    assert_match(/not proposed/, assert_raises(DreamRuling::Refused) { rule("approve", dream(status: "approved")) }.message)
    assert_match(/not proposed/, assert_raises(DreamRuling::Refused) { rule("drop", dream(status: "approved")) }.message)
    assert_match(/not approved/, assert_raises(DreamRuling::Refused) { rule("retire") }.message)
    assert_match(/not a ruling/, assert_raises(DreamRuling::Refused) { rule("bless") }.message)
    assert_equal 0, DreamApproval.count + DreamRetirement.count
  end

  test "[unit] an approval and a drop of one dream cannot both stand" do
    rule("approve")
    assert_match(/pending approval/, assert_raises(DreamRuling::Refused) { rule("drop") }.message)

    other = dream(slug: "other-habit")
    rule("drop", other)
    assert_match(/pending drop/, assert_raises(DreamRuling::Refused) { rule("approve", other) }.message)
  end

  test "[unit] a second ruling returns the first row, his click included" do
    click = DreamApproval.record!(dream, users(:alex))
    row, created = rule("approve")

    refute created
    assert_equal click.id, row.id
    assert_equal "click", row.reload.via
    assert_nil row.clearance
  end

  test "[unit] a chat row without its clearance or session is invalid" do
    row = DreamApproval.new(dream_home: "carl", dream_slug: "x", approved_at: Time.current, via: "chat")
    refute row.valid?
    assert row.errors.of_kind?(:clearance, :blank)
    refute DreamRetirement.new(dream_home: "carl", dream_slug: "x", retired_at: Time.current, ruling: "bless").valid?
  end
end
