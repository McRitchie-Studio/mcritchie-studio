require "test_helper"

# [integration] The communications table across its DB boundary: the things the
# MODEL layer cannot prove on its own — that the unique index really exists in
# Postgres, that NULL external ids really do coexist, that jsonb columns really
# round-trip, and that `processing` really is unbounded rather than merely
# declared so.
#
# The model test asserts the validation; this asserts the STORAGE. A uniqueness
# validation without its index loses a race, and a race is exactly what a
# re-ingest is.
class CommunicationsPersistenceTest < ActionDispatch::IntegrationTest
  def general(**overrides)
    Communication.create!({ kind: "general", channel: "email", occurred_at: 1.day.ago }.merge(overrides))
  end

  test "the unique index exists in the database, not just in the model" do
    indexes = ActiveRecord::Base.connection.indexes("communications")
    unique = indexes.find { |index| index.columns == %w[channel external_id] }

    assert unique, "expected an index on (channel, external_id)"
    assert unique.unique, "a uniqueness validation without its index loses the re-ingest race"
  end

  test "a duplicate (channel, external_id) is refused BY POSTGRES, bypassing validation" do
    general(external_id: "gmail-msg-1")

    # insert_all skips validations entirely — the shape a bulk re-ingest takes,
    # and the shape that finds out whether the index is real.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Communication.insert_all!([ { kind: "general", channel: "email", external_id: "gmail-msg-1",
                                    created_at: Time.current, updated_at: Time.current } ])
    end
  end

  test "the same external id on a DIFFERENT channel is a different thing" do
    general(external_id: "shared-id", channel: "email")

    assert_nothing_raised { general(external_id: "shared-id", channel: "slack") }
  end

  test "any number of rows may carry a NULL external id" do
    # Postgres treats NULLs as distinct in a unique index. That is intended, not
    # a hole: a hand-created ask has no external id and several must coexist.
    # It reads like a bug, so it is pinned.
    3.times { Communication.create!(kind: "ask", channel: "meeting", ask_text: "A question") }

    assert_equal 3, Communication.where(external_id: nil).count
  end

  test "an idempotent re-ingest is a find_or_create on the natural key" do
    first = Communication.find_or_create_by!(channel: "email", external_id: "gmail-msg-2") do |row|
      row.kind = "general"
      row.subject = "First pull"
    end
    second = Communication.find_or_create_by!(channel: "email", external_id: "gmail-msg-2") do |row|
      row.kind = "general"
      row.subject = "Second pull"
    end

    assert_equal first.id, second.id
    assert_equal "First pull", second.subject, "a re-pull must not rewrite what is already held"
    assert_equal 1, Communication.where(external_id: "gmail-msg-2").count
  end

  test "processing survives a round trip at a size no string column would take" do
    long = ([ "The reasoning, at length, with dead ends and citations." ] * 4_000).join(" ")
    row = Communication.create!(kind: "ask", channel: "email", ask_text: "Work this out",
                                processing: long)

    assert_operator long.bytesize, :>, 200_000
    assert_equal long, row.reload.processing
  end

  test "the jsonb columns round-trip structure, not strings" do
    row = Communication.create!(
      kind: "ask", channel: "email", ask_text: "Who is on this?",
      participants: [ { "name" => "A Person", "email" => "a@example.test",
                        "role" => "counsel", "side" => "theirs" } ],
      key_points: [ "The date moved", "The figure did not" ],
      tags: [ "schedule" ],
      access: { "samson" => "full", "dawn" => "aware" }
    ).reload

    assert_equal "counsel", row.participants.first["role"]
    assert_equal 2, row.key_points.size
    assert_equal "aware", row.access["dawn"]
    assert_instance_of Array, row.key_points
    assert_instance_of Hash, row.access
  end

  test "the jsonb defaults are containers, never nil" do
    row = Communication.create!(kind: "general", channel: "sms").reload

    assert_equal [], row.participants
    assert_equal [], row.tags
    assert_equal [], row.key_points
    assert_equal({}, row.access)
  end

  test "a privileged row is excluded from context by a DB query, not an in-memory filter" do
    ordinary = general(external_id: "ctx-1")
    general(external_id: "ctx-2", privileged: true)

    # Asserted on the SQL so a future refactor to an Array#reject cannot pass:
    # a filter that runs after the rows are loaded has already loaded them.
    assert_match(/privileged/, Communication.for_context.to_sql)
    assert_equal [ ordinary.id ], Communication.for_context.pluck(:id)
  end

  test "the board query is indexed for the shape the UI asks" do
    indexes = ActiveRecord::Base.connection.indexes("communications").map(&:columns)

    assert_includes indexes, %w[entity kind status], "the board filters on exactly this"
    assert_includes indexes, %w[thread_key], "everything on one conversation, across channels"
    assert_includes indexes, %w[occurred_at]
  end

  # ONE constraint violation PER TEST. Postgres aborts the surrounding
  # transaction on the first error, so a second insert in the same test comes
  # back as PG::InFailedSqlTransaction and asserts nothing about NOT NULL.
  test "kind is NOT NULL at the database level" do
    assert_raises(ActiveRecord::NotNullViolation) do
      Communication.insert_all!([ { channel: "email", created_at: Time.current,
                                    updated_at: Time.current } ])
    end
  end

  test "channel is NOT NULL at the database level" do
    assert_raises(ActiveRecord::NotNullViolation) do
      Communication.insert_all!([ { kind: "general", created_at: Time.current,
                                    updated_at: Time.current } ])
    end
  end
end
