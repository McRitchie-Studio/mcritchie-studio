require "test_helper"
require_relative "../support/agent_message_fixtures"
require Rails.root.join("db/migrate/20261016000000_add_held_to_agent_messages")

# [unit] The owner-only guard (docs/agents/system/agent-message-loop.md, "Held"):
# config/agent_answerers.yml resolves to people by identity and by person id;
# ingest stores an addressed message from anyone else `held`; the claim never
# returns a held row, nor a `received` one from a person the list does not allow;
# held and unallowed rows do not hold back the thread and person wait rules; an
# admin's release_hold! makes one message claimable; the CHECK knows `held`; and
# the migration's data step holds waiting rows from strangers only.
class AgentMessageHeldTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  ALEX = AgentPerson::OWNER[:external_id]
  STRANGER = "777000000000000001".freeze

  setup do
    # The real file, not the fixtures' unguarded double.
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @alex = AgentPerson.seed_owner!
  end

  def ingest(raw) = AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD)

  def mention_xan(id, author:, **opts) = ingest(discord_raw(id, content: "<@&#{XAN_ROLE}> status?", author: author, roles: [ XAN_ROLE ], **opts))

  def claim = AgentMessage.claim!(soul: "xan", worker: "w-#{SecureRandom.hex(3)}").message

  def stranger_person = AgentPerson.resolve!(platform: "discord", external_id: STRANGER, display_name: "Stranger")

  # --- allow-list resolution ---------------------------------------------------

  test "the shipped file allows Alex's person through his Discord identity, and nobody else" do
    answerers = AgentMessages::Answerers.load

    assert_equal [ @alex.id ], answerers.person_ids
    assert answerers.allowed?(@alex)
    refute answerers.allowed?(stranger_person)
    refute answerers.allowed?(nil), "a row with no person is never allowed"
  end

  test "an identity matches its person, so an identity later linked to Alex counts too; a person_id entry matches that row" do
    @alex.link_identity!(platform: "email", external_id: "alex@example.com")
    by_email = AgentMessages::Answerers.new([ { "identity" => { "platform" => "email", "external_id" => "alex@example.com" } } ])
    assert_equal [ @alex.id ], by_email.person_ids

    by_id = AgentMessages::Answerers.new([ { "name" => "S", "person_id" => stranger_person.id } ])
    assert by_id.allowed?(stranger_person)
    refute by_id.allowed?(@alex)
  end

  test "an identity nobody holds yet allows nobody, and the claim then hands out nothing (fail closed)" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new([ { "identity" => { "platform" => "discord", "external_id" => "1" } } ])
    assert_empty AgentMessages::Answerers.current.person_ids
    agent_message!(soul: "xan", author_ref: ALEX)

    assert_nil claim
  end

  test "a malformed entry is refused at load, not read as allow-all" do
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ { "name" => "nobody" } ]) }
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ "alex" ]) }
  end

  # --- ingest -----------------------------------------------------------------

  test "ingest stores Alex's mention received and a stranger's held, with an event saying why" do
    mine = mention_xan(1001, author: ALEX)
    theirs = mention_xan(1002, author: STRANGER)

    assert_equal "received", mine.status
    assert_equal @alex.id, mine.person_id
    assert_equal "held", theirs.status
    assert_equal "xan", theirs.soul_slug, "a held row keeps its soul, for the admin page and a release"
    held = theirs.events.find { |e| e.kind == "held" }
    assert_match(/not on config\/agent_answerers.yml/, held.detail["reason"])
    assert_equal theirs.person_id, held.detail["person_id"]
    assert_nil mine.events.find { |e| e.kind == "held" }
  end

  test "a stranger's reply into Alex's conversation joins the thread but is held" do
    mine = mention_xan(1101, author: ALEX)
    reply = ingest(discord_raw(1102, content: "me too", author: STRANGER, reply_to: mine.external_id))

    assert_equal mine.thread_key, reply.thread_key
    assert_equal "held", reply.status
  end

  # --- the claim guard ----------------------------------------------------------

  test "claim never returns a held row, nor a received row from an unallowed person, nor a row with no person" do
    mention_xan(1201, author: STRANGER)
    agent_message!(soul: "xan", author_ref: STRANGER) # somehow received: belt and braces
    agent_message!(soul: "xan")                       # no author, no person

    assert_nil claim
    assert_empty AgentMessage.claimable(soul: "xan")
  end

  test "a held or unallowed row older in a thread does not hold Alex's later message back" do
    mine = mention_xan(1301, author: ALEX)
    AgentMessage.claim!(soul: "xan", worker: "w0")
    mine.complete!(worker: "w0", response_text: "ok")
    mention_xan(1302, author: STRANGER, reply_to: mine.external_id)
    agent_message!(soul: "xan", author_ref: STRANGER, thread_key: mine.thread_key)
    later = ingest(discord_raw(1303, content: "and now?", author: ALEX, reply_to: mine.external_id))

    assert_equal "received", later.status
    assert_equal later.id, claim&.id
  end

  test "a held message does not hold back the same person's released message" do
    first = mention_xan(1401, author: STRANGER)
    second = mention_xan(1402, author: STRANGER)
    second.release_hold!(actor: "admin:test")

    assert_equal "held", first.reload.status
    assert_equal second.id, claim&.id
  end

  test "an unallowed row somehow received does not hold back the same person's released message" do
    agent_message!(soul: "xan", author_ref: STRANGER) # received, never claimable
    released = mention_xan(1451, author: STRANGER)
    released.release_hold!(actor: "admin:test")

    assert_equal released.id, claim&.id
  end

  # --- release ------------------------------------------------------------------

  test "release_hold! makes one held message claimable, records who did it, and the sender's next one is held" do
    held = mention_xan(1501, author: STRANGER)
    held.release_hold!(actor: "admin:alex")

    assert_equal "received", held.reload.status
    assert_equal "admin:alex", held.hold_released_by
    assert held.hold_released_at
    assert_equal "admin:alex", held.events.last.actor
    assert_equal "hold_released", held.events.last.kind
    assert_equal held.id, claim&.id
    assert_equal "held", mention_xan(1502, author: STRANGER).status
  end

  test "release_hold! refuses a message that is not held, and an empty actor" do
    mine = mention_xan(1601, author: ALEX)
    error = assert_raises(AgentMessage::Refused) { mine.release_hold!(actor: "admin:alex") }
    assert_equal "NOT_HELD", error.code

    held = mention_xan(1602, author: STRANGER)
    assert_equal "ACTOR_REQUIRED", assert_raises(AgentMessage::Refused) { held.release_hold!(actor: " ") }.code
    assert_equal "held", held.reload.status
  end

  # --- memory, constraint, migration ---------------------------------------------

  test "a held row never reaches an answer's thread layer" do
    mine = mention_xan(1701, author: ALEX)
    AgentMessage.claim!(soul: "xan", worker: "w0")
    mine.complete!(worker: "w0", response_text: "ok")
    mention_xan(1702, author: STRANGER, reply_to: mine.external_id)
    later = ingest(discord_raw(1703, content: "next", author: ALEX, reply_to: mine.external_id))

    turns = AgentMessages::MemoryBundle.new(later).bundle.dig("thread", "turns")
    assert_equal [ mine.id ], turns.map { |t| t["id"] }
  end

  test "the status CHECK holds every AgentMessage::STATUSES value, held among them" do
    definition = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'agent_messages_status_known'
    SQL
    assert_equal AgentMessage::STATUSES.sort, definition.scan(/'([a-z_]+)'::/).flatten.uniq.sort
    row = agent_message!(soul: "xan")
    AgentMessage.where(id: row.id).update_all(status: "held")
    assert_raises(ActiveRecord::CheckViolation) { AgentMessage.where(id: row.id).update_all(status: "parked") }
  end

  test "the migration's data step holds received rows from strangers and leaves Alex's and finished rows alone" do
    stranger_waiting = agent_message!(soul: "xan", author_ref: STRANGER)
    alex_waiting = agent_message!(soul: "xan", author_ref: ALEX)
    stranger_done = agent_message!(soul: "xan", author_ref: STRANGER, status: "completed")
    stranger_dead = agent_message!(soul: "xan", author_ref: STRANGER, status: "dead")

    migration = AddHeldToAgentMessages.new
    migration.verbose = false
    migration.send(:hold_unallowed_received!)

    assert_equal "held", stranger_waiting.reload.status
    assert_equal "held", stranger_waiting.events.last.kind
    assert_equal "received", alex_waiting.reload.status
    assert_equal "completed", stranger_done.reload.status
    assert_equal "dead", stranger_dead.reload.status
  end
end
