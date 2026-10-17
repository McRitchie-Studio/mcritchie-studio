require "test_helper"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [unit] A message typed into a CTO web chat (AgentMessages::WebIngest): the row
# it becomes, the soul and thread the server derives (never the request), whose
# person and audience it carries, the hold for an unanswered role, the go confirm,
# the rate limit, and the idempotent client id.
class WebIngestTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @alex_person = AgentPerson.seed_owner!
    @alex = users(:alex)
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  def cto(app_slug) = AppOwnership.cto_for_app(app_slug)

  def ingest(user, text, app: "turf-monster", client_id: nil, now: Time.current)
    AgentMessages::WebIngest.new(user: user, cto: cto(app), now: now).call(text, client_id: client_id)
  end

  test "the owner's message is a received web row for the app's CTO, on the owner's person" do
    message = ingest(@alex, "How are signups this week?")

    assert_equal %w[web turf_monster chat received], [ message.channel, message.soul_slug, message.routed_by, message.status ]
    assert_equal @alex_person, message.person, "the hub user an operator linked to the owner is the owner's person"
    assert_equal "web:turf-monster:#{@alex.id}", message.thread_key
    assert_equal "turf-monster", message.channel_ref
    assert_nil message.guild_id
    assert_equal @alex.id.to_s, message.author_ref
    assert AgentPersonIdentity.exists?(platform: "web", external_id: @alex.id.to_s, agent_person_id: @alex_person.id)
    assert_equal message, AgentMessage.claimable(soul: "turf_monster").first
    assert_equal({ "role" => "owner", "client_domain" => nil }, AgentPerson.audience_for(message.person))
  end

  test "the soul and thread follow the app: one thread per user per app, never another app's CTO" do
    turf = ingest(@alex, "turf?")
    studio = ingest(@alex, "studio?", app: "mcritchie-studio")

    assert_equal %w[turf_monster avi], [ turf.soul_slug, studio.soul_slug ]
    assert_not_equal turf.thread_key, studio.thread_key
    assert_equal "web:mcritchie-studio:#{@alex.id}", studio.thread_key
  end

  test "an app owner who is not the platform owner gets their own public person and is held, not answered" do
    message = ingest(@owner, "Hi Turf")

    assert_equal "held", message.status
    assert_equal "public", message.person.role, "app ownership grants no agent authority (Phase 6 is design only)"
    assert_equal @owner, message.person.user
    assert_equal [ "received", "routed", "held" ], message.events.map(&:kind)
    assert_match(/not answered/, message.events.last.detail["reason"])
    assert_nil AgentMessage.claimable(soul: "turf_monster").first
  end

  test "once an operator gives that person an answered role their next message is answered, as on Discord" do
    first = ingest(@owner, "one")
    first.person.set_role!("owner")

    assert_equal "received", ingest(@owner, "two").status
  end

  test "the same client id stores one row; another thread's client id never returns that thread's row" do
    first = ingest(@alex, "once", client_id: "client-abcdef12")
    assert_no_difference -> { AgentMessage.count } do
      assert_equal first, ingest(@alex, "once", client_id: "client-abcdef12")
    end

    other = ingest(@alex, "elsewhere", app: "mcritchie-studio", client_id: "client-abcdef12")
    assert_not_equal first, other
    assert_equal "web:mcritchie-studio:#{@alex.id}", other.thread_key
  end

  test "an empty, an over-long, and a no-web-chat message are refused and store nothing" do
    assert_no_difference -> { AgentMessage.count } do
      assert_equal "EMPTY", assert_raises(AgentMessages::WebIngest::Refused) { ingest(@alex, "  \n ") }.code
      too_long = "x" * (AgentMessages::WebIngest::MAX_LENGTH + 1)
      assert_equal "TOO_LONG", assert_raises(AgentMessages::WebIngest::Refused) { ingest(@alex, too_long) }.code
    end

    routes = AgentMessages::Routes.new("web" => { "souls" => [ "avi" ] })
    refused = assert_raises(AgentMessages::WebIngest::Refused) do
      AgentMessages::WebIngest.new(user: @alex, cto: cto("turf-monster"), routes: routes).call("hi")
    end
    assert_equal "NO_WEB_CHAT", refused.code
  end

  test "past the rate limit in the window the next message is held with a rate_limited event" do
    now = Time.current
    AgentMessages::WebIngest::RATE_LIMIT.times do |i|
      AgentMessage.create!(channel: "web", external_id: "#{@alex.id}:seed-#{i}", channel_ref: "turf-monster",
                           thread_key: "web:turf-monster:#{@alex.id}", soul_slug: "turf_monster", status: "completed",
                           content: "seed", person: @alex_person, author_ref: @alex.id.to_s, created_at: now - 5.minutes)
    end

    message = ingest(@alex, "one more", now: now)
    assert_equal "held", message.status
    assert message.events.exists?(kind: "rate_limited")
  end

  test "the owner's go in the thread confirms its pending proposal in code, before any model" do
    source = ingest(@alex, "Open a task for the scores bug")
    proposal = AgentProposal.create!(thread_key: source.thread_key, channel: "web", guild_id: nil, channel_ref: "turf-monster",
                                     soul_slug: "turf_monster", person: @alex_person, source_message: source,
                                     kind: "change", capability: "task", params: { "title" => "Fix scores" },
                                     summary: "Open a task", status: "proposed", expires_at: 1.day.from_now)
    source.update!(status: "completed", response_text: "I can open that.")

    go = nil
    assert_enqueued_with(job: AgentProposalJob, args: [ proposal.id ]) { go = ingest(@alex, "go") }
    assert_equal %w[completed thread], [ go.status, go.routed_by ]
    assert_equal "confirmed", proposal.reload.status
  end

  test "a go from a person who may not confirm is held with confirm_refused, and nothing runs" do
    source = ingest(@owner, "please")
    proposal = AgentProposal.create!(thread_key: source.thread_key, channel: "web", guild_id: nil, channel_ref: "turf-monster",
                                     soul_slug: "turf_monster", person: source.person, source_message: source,
                                     kind: "change", capability: "task", params: { "title" => "x" },
                                     summary: "x", status: "proposed", expires_at: 1.day.from_now)

    go = nil
    assert_no_enqueued_jobs(only: AgentProposalJob) { go = ingest(@owner, "go") }
    assert_equal "held", go.status
    assert go.events.exists?(kind: "confirm_refused")
    assert_equal "proposed", proposal.reload.status
  end

  test "person_for reuses the user's web identity and never matches a person by name" do
    namesake = AgentPerson.create!(display_name: @owner.display_name)
    person = AgentMessages::WebIngest.person_for(@owner)

    assert_not_equal namesake, person
    assert_equal person, AgentMessages::WebIngest.person_for(@owner)
    assert_equal 1, AgentPersonIdentity.where(platform: "web", external_id: @owner.id.to_s).count
  end

  test "the web chat's CTOs are routed: the board and bin/dispatcher both serve them, Tyrion included" do
    routes = AgentMessages::Routes.load
    assert_equal %w[avi turf_monster tyrion], routes.web_souls
    assert_includes routes.souls, "tyrion", "no guild routes Tyrion; the web chat does"
    assert_includes AgentMailbox.routed_souls, "tyrion"
    assert_includes AgentMailbox::Dispatcher::TYPING_CHANNELS, "web"
    assert_equal AgentMessage::TYPING_CHANNELS, AgentMailbox::Dispatcher::TYPING_CHANNELS, "board and worker agree"
  end

  test "Alex's other hub accounts are the owner's web identities; nobody else's is" do
    turf_alex = User.create!(email: "alex@turfmonster.media", name: "Alex", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: turf_alex)
    AgentPerson.seed_owner!

    assert_equal @alex_person, AgentMessages::WebIngest.person_for(turf_alex)
    assert_equal "received", ingest(turf_alex, "from my Turf account").status
    assert_not AgentPersonIdentity.exists?(platform: "web", external_id: @owner.id.to_s, agent_person_id: @alex_person.id)
  end

  test "the migration links the same accounts to the owner, idempotently, and never moves another's identity" do
    require Rails.root.join("db/migrate/20261017010000_link_owner_web_identities").to_s
    turf_alex = User.create!(email: "alex@turfmonster.media", name: "Alex", role: "viewer")
    gmail_alex = User.create!(email: "AMcritchie@gmail.com", name: "Alex", role: "viewer")
    AgentPersonIdentity.where(platform: "web").delete_all
    stranger = AgentPerson.create!(display_name: "Someone")
    stranger.identities.create!(platform: "web", external_id: gmail_alex.id.to_s)

    migration = LinkOwnerWebIdentities.new
    migration.verbose = false
    2.times { migration.up }

    linked = AgentPersonIdentity.where(platform: "web").pluck(:external_id, :agent_person_id).to_h
    assert_equal @alex_person.id, linked[@alex.id.to_s]
    assert_equal @alex_person.id, linked[turf_alex.id.to_s]
    assert_equal stranger.id, linked[gmail_alex.id.to_s], "an identity that belongs to someone is never moved"
    assert_nil linked[@owner.id.to_s]
  end
end
