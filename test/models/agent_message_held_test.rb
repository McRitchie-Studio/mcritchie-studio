require "test_helper"
require "tmpdir"
require_relative "../support/agent_message_fixtures"
require Rails.root.join("db/migrate/20261016000000_add_held_to_agent_messages")

# [unit] The owner-only guard (docs/agents/system/agent-message-loop.md, "Held"):
# config/agent_answerers.yml answers ROLES (owner only), so a person is answered by
# their role, which an operator sets and a message cannot;
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

  def mention_ray(id, author:, **opts) = ingest(discord_raw(id, content: "<@&#{RAY_ROLE}> status?", author: author, roles: [ RAY_ROLE ], **opts))

  def claim = AgentMessage.claim!(soul: "alex", worker: "w-#{SecureRandom.hex(3)}").message

  def stranger_person = AgentPerson.resolve!(platform: "discord", external_id: STRANGER, display_name: "Stranger")

  # --- answered roles (the allow-list folded into the owner role) ---------------

  test "the shipped file answers the owner role only: Alex McRitchie's person, and nobody else" do
    answerers = AgentMessages::Answerers.load

    assert_equal [ "owner" ], answerers.roles
    assert_equal [ @alex.id ], answerers.person_ids
    assert answerers.allowed?(@alex)
    refute answerers.allowed?(stranger_person)
    refute answerers.allowed?(nil), "a row with no person is never allowed"
  end

  test "an identity later linked to Alex McRitchie is answered with him, because the role is on his person" do
    @alex.link_identity!(platform: "email", external_id: "alex@example.com")
    linked = AgentPersonIdentity.find_by!(platform: "email", external_id: "alex@example.com").person
    assert AgentMessages::Answerers.load.allowed?(linked)
  end

  test "a role change is seen at once by the claim, with no reload; a role not listed stays held back" do
    stranger = stranger_person
    agent_message!(soul: "alex", author_ref: STRANGER)
    assert_nil claim, "public is not answered"

    stranger.set_role!("team")
    assert_nil claim, "team is not answered while the list is owner only"

    AgentMessages::Answerers.current = AgentMessages::Answerers.new(%w[owner team])
    assert_equal stranger.id, claim&.person_id
    assert AgentMessages::Answerers.current.allowed?(stranger)

    stranger.set_role!("owner")
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    assert AgentMessages::Answerers.current.allowed?(stranger.reload)
  end

  test "an empty list answers nobody, and the claim then hands out nothing (fail closed)" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new([])
    assert_empty AgentMessages::Answerers.current.person_ids
    agent_message!(soul: "alex", author_ref: ALEX)

    assert_nil claim
  end

  test "a malformed list or an unknown role is refused at load, not read as allow-all" do
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ "admin" ]) }
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new("owner") }
    assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.new([ "owner'); --" ]) }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "answerers.yml")
      File.write(path, "answerers:\n  - name: Alex McRitchie\n")
      assert_raises(AgentMessages::Answerers::Invalid) { AgentMessages::Answerers.load(path) }
    end
  end

  # --- ingest -----------------------------------------------------------------

  test "ingest stores Alex McRitchie's mention received and a stranger's held, with an event saying why" do
    mine = mention_ray(1001, author: ALEX)
    theirs = mention_ray(1002, author: STRANGER)

    assert_equal "received", mine.status
    assert_equal @alex.id, mine.person_id
    assert_equal "held", theirs.status
    assert_equal "alex", theirs.soul_slug, "a held row keeps its soul, for the admin page and a release"
    held = theirs.events.find { |e| e.kind == "held" }
    assert_equal "sender's role (public) is not answered; config/agent_answerers.yml answers owner (and an app's owner on that app's own CTO chat only)", held.detail["reason"]
    assert_equal theirs.person_id, held.detail["person_id"]
    assert_nil mine.events.find { |e| e.kind == "held" }
  end

  test "a stranger's reply into Alex McRitchie's conversation joins the thread but is held" do
    mine = mention_ray(1101, author: ALEX)
    reply = ingest(discord_raw(1102, content: "me too", author: STRANGER, reply_to: mine.external_id))

    assert_equal mine.thread_key, reply.thread_key
    assert_equal "held", reply.status
  end

  # --- the claim guard ----------------------------------------------------------

  test "claim never returns a held row, nor a received row from an unallowed person, nor a row with no person" do
    mention_ray(1201, author: STRANGER)
    agent_message!(soul: "alex", author_ref: STRANGER) # somehow received: belt and braces
    agent_message!(soul: "alex")                       # no author, no person

    assert_nil claim
    assert_empty AgentMessage.claimable(soul: "alex")
  end

  test "a held or unallowed row older in a thread does not hold Alex McRitchie's later message back" do
    mine = mention_ray(1301, author: ALEX)
    AgentMessage.claim!(soul: "alex", worker: "w0")
    mine.complete!(worker: "w0", response_text: "ok")
    mention_ray(1302, author: STRANGER, reply_to: mine.external_id)
    agent_message!(soul: "alex", author_ref: STRANGER, thread_key: mine.thread_key)
    later = ingest(discord_raw(1303, content: "and now?", author: ALEX, reply_to: mine.external_id))

    assert_equal "received", later.status
    assert_equal later.id, claim&.id
  end

  test "a held message does not hold back the same person's released message" do
    first = mention_ray(1401, author: STRANGER)
    second = mention_ray(1402, author: STRANGER)
    second.release_hold!(actor: "admin:test")

    assert_equal "held", first.reload.status
    assert_equal second.id, claim&.id
  end

  test "an unallowed row somehow received does not hold back the same person's released message" do
    agent_message!(soul: "alex", author_ref: STRANGER) # received, never claimable
    released = mention_ray(1451, author: STRANGER)
    released.release_hold!(actor: "admin:test")

    assert_equal released.id, claim&.id
  end

  # --- release ------------------------------------------------------------------

  test "release_hold! makes one held message claimable, records who did it, and the sender's next one is held" do
    held = mention_ray(1501, author: STRANGER)
    held.release_hold!(actor: "admin:alex")

    assert_equal "received", held.reload.status
    assert_equal "admin:alex", held.hold_released_by
    assert held.hold_released_at
    assert_equal "admin:alex", held.events.last.actor
    assert_equal "hold_released", held.events.last.kind
    assert_equal held.id, claim&.id
    assert_equal "held", mention_ray(1502, author: STRANGER).status
  end

  test "release_hold! refuses a message that is not held, and an empty actor" do
    mine = mention_ray(1601, author: ALEX)
    error = assert_raises(AgentMessage::Refused) { mine.release_hold!(actor: "admin:alex") }
    assert_equal "NOT_HELD", error.code

    held = mention_ray(1602, author: STRANGER)
    assert_equal "ACTOR_REQUIRED", assert_raises(AgentMessage::Refused) { held.release_hold!(actor: " ") }.code
    assert_equal "held", held.reload.status
  end

  # --- memory, constraint, migration ---------------------------------------------

  test "a held row never reaches an answer's thread layer" do
    mine = mention_ray(1701, author: ALEX)
    AgentMessage.claim!(soul: "alex", worker: "w0")
    mine.complete!(worker: "w0", response_text: "ok")
    mention_ray(1702, author: STRANGER, reply_to: mine.external_id)
    later = ingest(discord_raw(1703, content: "next", author: ALEX, reply_to: mine.external_id))

    turns = AgentMessages::MemoryBundle.new(later).bundle.dig("thread", "turns")
    assert_equal [ mine.id ], turns.map { |t| t["id"] }
  end

  test "the status CHECK holds every AgentMessage::STATUSES value, held among them" do
    definition = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'agent_messages_status_known'
    SQL
    assert_equal AgentMessage::STATUSES.sort, definition.scan(/'([a-z_]+)'::/).flatten.uniq.sort
    row = agent_message!(soul: "alex")
    AgentMessage.where(id: row.id).update_all(status: "held")
    assert_raises(ActiveRecord::CheckViolation) { AgentMessage.where(id: row.id).update_all(status: "parked") }
  end

  test "the migration's data step holds received rows from strangers and leaves Alex McRitchie's and finished rows alone" do
    stranger_waiting = agent_message!(soul: "alex", author_ref: STRANGER)
    alex_waiting = agent_message!(soul: "alex", author_ref: ALEX)
    stranger_done = agent_message!(soul: "alex", author_ref: STRANGER, status: "completed")
    stranger_dead = agent_message!(soul: "alex", author_ref: STRANGER, status: "dead")

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
