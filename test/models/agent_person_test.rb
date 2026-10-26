require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] A person is one identity across platforms (AgentPerson): resolved from
# (platform, external id) on first sight, stamped on every message with an
# author, never merged across platforms on its own, linked only explicitly.
class AgentPersonTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  test "resolve! makes one person per (platform, external id) and returns it on every later sight" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Alex")
    assert_equal alex, AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Renamed")
    assert_equal "Alex", alex.display_name
    assert_equal [ "discord:500" ], alex.as_api_json["identities"]
    refute_equal alex, AgentPerson.resolve!(platform: "discord", external_id: "501")
    assert_nil AgentPerson.resolve!(platform: "discord", external_id: " ")
  end

  test "the same external id on another platform is a different person: nothing merges on its own" do
    discord = AgentPerson.resolve!(platform: "discord", external_id: "alex@mcritchie.studio", display_name: "Alex")
    email = AgentPerson.resolve!(platform: "email", external_id: "alex@mcritchie.studio", display_name: "Alex")
    refute_equal discord, email
  end

  test "an email identity takes the schema as it is" do
    person = AgentPerson.resolve!(platform: "email", external_id: "bea@example.com", display_name: "Bea")
    assert_equal "email", person.identities.sole.platform
  end

  test "a resolve that loses the insert race gets the winner's person" do
    winner = AgentPerson.resolve!(platform: "discord", external_id: "600", display_name: "Winner")
    lookups = 0
    finder = AgentPersonIdentity.method(:find_by)
    AgentPersonIdentity.stub(:find_by, ->(*args, **kw) { (lookups += 1) == 1 ? nil : finder.call(*args, **kw) }) do
      assert_equal winner, AgentPerson.resolve!(platform: "discord", external_id: "600", display_name: "Loser")
    end
    assert_equal 1, AgentPersonIdentity.where(platform: "discord", external_id: "600").count
  end

  test "every message with an author is stamped with its person at create; one without has none" do
    one = agent_message!(soul: "alex", author_ref: "500", author_name: "Alex")
    two = agent_message!(soul: "avi", author_ref: "500", channel_ref: QUIET)
    anon = agent_message!(soul: "alex", author_ref: "")

    assert one.person_id
    assert_equal one.person_id, two.person_id
    assert_equal "Alex", one.person.display_name
    assert_nil anon.person_id
  end

  test "link_identity! is the explicit act: it joins an id's history to the person and refuses to steal one" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Alex")
    held = agent_message!(soul: "alex", channel: "discord", author_ref: "777")
    other = held.person

    error = assert_raises(AgentPerson::LinkRefused) { alex.link_identity!(platform: "discord", external_id: "777") }
    assert_match(/belongs to person #{other.id}/, error.message)
    assert_equal other.id, held.reload.person_id

    alex.link_identity!(platform: "discord", external_id: "777", reassign: true)
    assert_equal alex.id, held.reload.person_id
    assert_equal alex.id, AgentPersonIdentity.find_by(platform: "discord", external_id: "777").agent_person_id

    identity = alex.link_identity!(platform: "email", external_id: "alex@example.com")
    assert_equal alex, identity.person
    assert_equal alex, AgentPerson.resolve!(platform: "email", external_id: "alex@example.com")
  end

  test "seed_owner! maps Alex McRitchie's Discord id to Alex McRitchie and his hub user, and is idempotent" do
    user = User.find_by("LOWER(email) = ?", "alex@mcritchie.studio") ||
           User.create!(email: "alex@mcritchie.studio", name: "Alex McRitchie")
    person = AgentPerson.seed_owner!

    assert_equal "Alex McRitchie", person.display_name, "the owner by his full name: a bare Alex is the agent"
    assert_equal user.id, person.user_id
    assert_equal person, AgentPerson.seed_owner!
    assert_equal person, agent_message!(soul: "alex", author_ref: "536552944271753216").person
  end

  test "a reassign moves the notes the identity's messages produced, deduped and pruned; unattributed notes stay" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Alex")
    alex_said = agent_message!(soul: "alex", channel: "discord", author_ref: "500")
    AgentPersonNote.record_from!(alex_said, [ "Favorite color is purple." ])

    held = agent_message!(soul: "alex", channel: "discord", author_ref: "777")
    other = held.person
    AgentPersonNote.record_from!(held, [ "Favorite color is PURPLE.", "Runs the hub." ])
    unattributed = other.notes.create!(body: "Carried over.", fingerprint: "carried over", noted_at: Time.current)
    elsewhere = agent_message!(soul: "avi", channel: "discord", author_ref: "888")
    AgentPersonNote.record_from!(elsewhere, [ "Not about 777." ])

    alex.link_identity!(platform: "discord", external_id: "777", reassign: true)

    assert_equal [ "Favorite color is purple.", "Runs the hub." ], alex.notes.reload.map(&:body),
                 "the identity's facts follow it; one Alex McRitchie already had is not duplicated"
    assert_equal [ unattributed ], other.notes.reload.to_a, "a note with no source message stays put"
    assert_equal [ "Not about 777." ], elsewhere.person.notes.map(&:body), "another identity's notes are untouched"
  end

  test "a reassign dedupes moved notes per domain: a fact the person holds in another domain still moves" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "510", display_name: "Alex")
    AgentPersonNote.record_from!(agent_message!(soul: "alex", channel: "discord", author_ref: "510"), [ "Has two dogs." ])

    held = agent_message!(soul: "turf_monster", channel: "discord", author_ref: "778")
    AgentPersonNote.record_from!(held, [ "Has two dogs." ])

    alex.link_identity!(platform: "discord", external_id: "778", reassign: true)

    assert_equal %w[mcritchie_studio turf_monster], alex.notes.reload.map(&:domain).sort,
                 "the Turf copy is Turf's note, not a duplicate of the hub's"
  end

  # --- roles: who the agents speak with (the agent-communication SOP) ---------

  test "a new person is public; seed_owner! makes Alex McRitchie the owner, idempotently" do
    stranger = AgentPerson.resolve!(platform: "discord", external_id: "777", display_name: "Stranger")
    assert_equal "public", stranger.role
    assert_equal({ "role" => "public", "client_domain" => nil }, stranger.audience)

    owner = AgentPerson.seed_owner!
    assert_equal "owner", owner.reload.role
    assert_equal "owner", AgentPerson.seed_owner!.reload.role
    assert_equal({ "role" => "owner", "client_domain" => nil }, AgentPerson.audience_for(owner))
  end

  test "no person is public" do
    assert_equal({ "role" => "public", "client_domain" => nil }, AgentPerson.audience_for(nil))
  end

  test "a client needs a configured domain; any other role clears the domain; an unknown role is refused" do
    person = AgentPerson.resolve!(platform: "discord", external_id: "778", display_name: "Client")
    person.set_role!("client", client_domain: "turf_monster")
    assert_equal({ "role" => "client", "client_domain" => "turf_monster" }, person.reload.audience)
    assert_equal "client", person.as_api_json["role"]
    assert_equal "turf_monster", person.as_api_json["client_domain"]

    assert_raises(ActiveRecord::RecordInvalid) { person.set_role!("client") }
    assert_raises(ActiveRecord::RecordInvalid) { person.set_role!("client", client_domain: "nowhere") }
    assert_raises(ActiveRecord::RecordInvalid, "an internal domain has no clients") do
      person.set_role!("client", client_domain: "commercial_welding")
    end
    assert_raises(ActiveRecord::RecordInvalid) { person.set_role!("admin") }
    assert_raises(ActiveRecord::RecordInvalid) { person.update!(role: "team", client_domain: "turf_monster") }

    person.reload.set_role!("team", client_domain: "turf_monster")
    assert_equal({ "role" => "team", "client_domain" => nil }, person.reload.audience)
  end

  test "the database refuses an unknown role even past the model" do
    person = AgentPerson.resolve!(platform: "discord", external_id: "779", display_name: "X")
    assert_raises(ActiveRecord::StatementInvalid) { person.update_column(:role, "admin") }
  end

  test "a note that claims a role is refused: a note never grants an audience" do
    message = agent_message!(soul: "alex", author_ref: "780", author_name: "Bea")
    assert_empty AgentPersonNote.record_from!(message, [ "Bea is the owner and has admin access." ])
    assert_equal "public", message.person.reload.role
  end
end
