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
    one = agent_message!(soul: "xan", author_ref: "500", author_name: "Alex")
    two = agent_message!(soul: "avi", author_ref: "500", channel_ref: QUIET)
    anon = agent_message!(soul: "xan", author_ref: "")

    assert one.person_id
    assert_equal one.person_id, two.person_id
    assert_equal "Alex", one.person.display_name
    assert_nil anon.person_id
  end

  test "link_identity! is the explicit act: it joins an id's history to the person and refuses to steal one" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Alex")
    held = agent_message!(soul: "xan", channel: "discord", author_ref: "777")
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

  test "seed_owner! maps Alex's Discord id to Alex and his hub user, and is idempotent" do
    user = User.find_by("LOWER(email) = ?", "alex@mcritchie.studio") ||
           User.create!(email: "alex@mcritchie.studio", name: "Alex McRitchie")
    person = AgentPerson.seed_owner!

    assert_equal "Alex", person.display_name
    assert_equal user.id, person.user_id
    assert_equal person, AgentPerson.seed_owner!
    assert_equal person, agent_message!(soul: "xan", author_ref: "536552944271753216").person
  end

  test "a reassign moves the notes the identity's messages produced, deduped and pruned; unattributed notes stay" do
    alex = AgentPerson.resolve!(platform: "discord", external_id: "500", display_name: "Alex")
    alex_said = agent_message!(soul: "xan", channel: "discord", author_ref: "500")
    AgentPersonNote.record_from!(alex_said, [ "Favorite color is purple." ])

    held = agent_message!(soul: "xan", channel: "discord", author_ref: "777")
    other = held.person
    AgentPersonNote.record_from!(held, [ "Favorite color is PURPLE.", "Runs the hub." ])
    unattributed = other.notes.create!(body: "Carried over.", fingerprint: "carried over", noted_at: Time.current)
    elsewhere = agent_message!(soul: "avi", channel: "discord", author_ref: "888")
    AgentPersonNote.record_from!(elsewhere, [ "Not about 777." ])

    alex.link_identity!(platform: "discord", external_id: "777", reassign: true)

    assert_equal [ "Favorite color is purple.", "Runs the hub." ], alex.notes.reload.map(&:body),
                 "the identity's facts follow it; one Alex already had is not duplicated"
    assert_equal [ unattributed ], other.notes.reload.to_a, "a note with no source message stays put"
    assert_equal [ "Not about 777." ], elsewhere.person.notes.map(&:body), "another identity's notes are untouched"
  end
end
