require "test_helper"

# [unit] Communication — the two kinds, the terse/unbounded split, and the
# privileged default. Synthetic names throughout: this repo is private, but a
# fixture that names a real counterparty ends up in failure output, and failure
# output travels.
class CommunicationTest < ActiveSupport::TestCase
  def general(**overrides)
    Communication.new({ kind: "general", channel: "email",
                        occurred_at: 1.day.ago, subject: "Weekly note" }.merge(overrides))
  end

  def ask(**overrides)
    Communication.new({ kind: "ask", channel: "email", ask_text: "Draft a reply about the schedule.",
                        occurred_at: 1.hour.ago }.merge(overrides))
  end

  # --- kinds and enums -------------------------------------------------------

  test "a general row is valid with just a kind and a channel" do
    assert general.valid?
  end

  test "kind and channel are constrained; direction and status are optional-but-checked" do
    refute general(kind: "memo").valid?
    refute general(channel: "carrier_pigeon").valid?
    refute general(direction: "sideways").valid?
    assert general(direction: nil).valid?, "direction is genuinely optional"
  end

  test "every named channel is accepted, including the deliberate escape hatch" do
    Communication::CHANNELS.each do |channel|
      assert general(channel: channel).valid?, "#{channel} should be a legal channel"
    end
    assert_includes Communication::CHANNELS, "other",
      "an unlisted channel must land as a reclassifiable row, not be refused at the door"
  end

  test "kind and channel normalize, so ingest casing cannot fragment the enum" do
    row = general(kind: " GENERAL ", channel: "Email")
    assert row.valid?, row.errors.full_messages.join("; ")
    assert_equal "general", row.kind
    assert_equal "email", row.channel
  end

  # --- the ask contract ------------------------------------------------------

  test "an ask must say what was asked" do
    refute ask(ask_text: nil).valid?
    assert_includes ask(ask_text: nil).tap(&:valid?).errors[:ask_text], "can't be blank"
  end

  test "an ask with no status defaults to open rather than nil" do
    # Left to callers this is the field that ends up nil on half the rows and
    # quietly breaks the board query.
    record = ask
    record.valid?
    assert_equal "open", record.status
  end

  test "an ask's status is constrained to the lifecycle" do
    refute ask(status: "pondering").valid?
    Communication::STATUSES.each { |status| assert ask(status: status).valid?, status }
  end

  test "a general row cannot carry ask fields" do
    # Not pedantry: a `general` row with a status is something classified wrong,
    # and finding that months later is far harder than refusing it now.
    Communication::ASK_ONLY_FIELDS.each do |field|
      value = case field
      when :due_at then 1.day.from_now
      else "something"
      end
      row = general(field => value)
      refute row.valid?, "#{field} should not be allowed on a general row"
      assert_match(/cannot carry ask fields/, row.errors.full_messages.join)
    end

    row = general(key_points: [ "a point" ])
    refute row.valid?
  end

  # --- the terse / unbounded split ------------------------------------------

  test "processing is unbounded — the whole reason it is a separate column" do
    long = "reasoning. " * 5_000
    record = ask(processing: long)

    assert record.save!
    assert_equal long.length, record.reload.processing.length
    assert_operator record.processing.length, :>, 50_000
  end

  test "a key point over the cap is refused, and the message says where it belongs" do
    record = ask(key_points: [ "a" * (Communication::KEY_POINT_MAX + 1) ])

    refute record.valid?
    message = record.errors.full_messages.join
    assert_match(/#{Communication::KEY_POINT_MAX}/, message)
    assert_match(/processing/, message, "the error must point at the column that takes long form")
  end

  test "a key point exactly at the cap is fine" do
    assert ask(key_points: [ "a" * Communication::KEY_POINT_MAX ]).valid?
  end

  test "key points must be non-blank strings" do
    refute ask(key_points: [ "fine", "" ]).valid?
    refute ask(key_points: [ "fine", "   " ]).valid?
    refute ask(key_points: [ { "point" => "nested" } ]).valid?
    refute ask(key_points: [ 42 ]).valid?
  end

  test "a non-Array key_points is refused, so the cap cannot be skipped by changing the type" do
    # jsonb takes a scalar or an object as happily as an array. A validator that
    # returned early on a non-Array let the 200-character cap be bypassed by
    # sending a bare String — exactly the `processing`-into-`key_points`
    # collapse the cap exists to prevent.
    [ "x" * 5_000, { "point" => "x" * 5_000 }, 42, true ].each do |value|
      record = ask(key_points: value)

      refute record.valid?, "key_points as #{value.class} should be refused"
      assert_match(/must be an array/, record.errors.full_messages.join)
    end
  end

  test "the offending key point is named by position" do
    record = ask(key_points: [ "ok", "also ok", "x" * 500 ])
    record.valid?

    assert_match(/entry 3/, record.errors.full_messages.join)
  end

  # --- participants and access ----------------------------------------------

  test "participants must be a list of records" do
    assert ask(participants: [ { "name" => "A Person", "email" => "a@example.test",
                                 "role" => "counsel", "side" => "theirs" } ]).valid?
    refute ask(participants: "a@example.test").valid?
    refute ask(participants: [ "a@example.test" ]).valid?
  end

  test "the access map uses the knowledge layer's own levels" do
    assert_equal Studio::KnowledgeDoc::ACCESS_LEVELS.sort, %w[aware full none]
    assert ask(access: { "samson" => "full", "dawn" => "none" }).valid?
    refute ask(access: { "samson" => "readonly" }).valid?
    refute ask(access: [ "samson" ]).valid?
  end

  # --- the privileged guardrail ---------------------------------------------

  test "privileged defaults to false, so nothing is accidentally sealed" do
    refute general.tap(&:save!).reload.privileged?
  end

  test "for_context EXCLUDES privileged rows by default" do
    ordinary = general(external_id: "m-ordinary").tap(&:save!)
    sealed = general(external_id: "m-sealed", privileged: true).tap(&:save!)

    assert_includes Communication.for_context, ordinary
    refute_includes Communication.for_context, sealed,
      "attorney-client material must never reach a draft's context unasked"
  end

  test "for_context includes privileged rows only when asked BY NAME" do
    sealed = general(external_id: "m-sealed-2", privileged: true).tap(&:save!)

    assert_includes Communication.for_context(including_privileged: true), sealed
  end

  test "contextable? answers the same question per row" do
    refute general(privileged: true).contextable?
    assert general(privileged: true).contextable?(including_privileged: true)
    assert general.contextable?
  end

  # --- scopes the UI and the pipeline both need -----------------------------

  test "board_order puts asks first, then newest first" do
    old_general = general(external_id: "g-old", occurred_at: 10.days.ago).tap(&:save!)
    new_general = general(external_id: "g-new", occurred_at: 1.hour.ago).tap(&:save!)
    old_ask = ask(external_id: "a-old", occurred_at: 9.days.ago).tap(&:save!)
    new_ask = ask(external_id: "a-new", occurred_at: 2.hours.ago).tap(&:save!)

    assert_equal [ new_ask, old_ask, new_general, old_general ], Communication.board_order.to_a
  end

  test "a row with no occurred_at sorts last rather than first" do
    dated = general(external_id: "g-dated", occurred_at: 5.days.ago).tap(&:save!)
    undated = general(external_id: "g-undated", occurred_at: nil).tap(&:save!)

    assert_equal [ dated, undated ], Communication.newest_first.to_a,
      "NULLS LAST — an undated row is unknown, not newest"
  end

  test "open_asks covers the in-flight states only" do
    open_one = ask(external_id: "a1", status: "open").tap(&:save!)
    researching = ask(external_id: "a2", status: "researching").tap(&:save!)
    drafted = ask(external_id: "a3", status: "drafted").tap(&:save!)
    delivered = ask(external_id: "a4", status: "delivered").tap(&:save!)
    closed = ask(external_id: "a5", status: "closed").tap(&:save!)

    assert_equal [ open_one, researching, drafted ].map(&:id).sort,
                 Communication.open_asks.pluck(:id).sort
    refute_includes Communication.open_asks, delivered
    refute_includes Communication.open_asks, closed
  end

  test "entity, channel and thread scopes compose" do
    match = ask(entity: "synthetic-entity", channel: "slack", thread_key: "t-1",
                external_id: "x1").tap(&:save!)
    ask(entity: "other-entity", channel: "slack", thread_key: "t-1", external_id: "x2").save!

    assert_equal [ match ], Communication.for_entity("synthetic-entity").on_channel("slack")
                                         .on_thread("t-1").asks.to_a
  end
end
