require "test_helper"

# [unit] An app owner's word on a proposal (Alex, 2026-10-18: "the app owner
# should have that access"; AgentMessages::ProposalConfirm#owner_verdict), with
# the shipped config/agent_answerers.yml. The owner may say go, no or change: on
# a proposal only on their OWN app's web CTO thread, only for a kind a client of
# the app may build (change), and only under the app's owner meter. Everywhere
# else (Discord, email, another app, another user's thread, an app they do not
# own, a held person, a team-role owner) the word is refused and nothing runs.
# The owner role (Alex) is unchanged: any thread, any kind, uncapped.
class ProposalConfirmAppOwnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  CHANGE = { "title" => "Show kickoff times", "kind" => "feature", "shape" => "backend",
             "accept" => [ "Each game row shows its kickoff time" ], "test" => [ "[unit] kickoff time renders" ],
             "risk" => [] }.freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @alex = AgentPerson.seed_owner!
    @turf = apps(:turf_monster)
    @user = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: @turf, user: @user)
    @person = AgentMessages::WebIngest.person_for(@user)
  end

  teardown { AgentMessages::Answerers.reset! }

  def ingest(user, text, app: "turf-monster")
    AgentMessages::WebIngest.new(user: user, cto: AppOwnership.cto_for_app(app)).call(text)
  end

  # A pending proposal on `user`'s own web thread with `app`'s CTO, from an
  # answered message there.
  def proposal!(user: @user, person: AgentMessages::WebIngest.person_for(user), app: "turf-monster", soul: "turf_monster",
                kind: "change", capability: "task", params: CHANGE)
    source = AgentMessage.create!(channel: "web", external_id: SecureRandom.uuid, channel_ref: app,
                                  thread_key: AgentMessages::WebChat.thread_key(app, user.id), soul_slug: soul,
                                  content: "Can you add it?", person: person, status: "completed",
                                  completed_at: Time.current, response_text: "I can open a task.", author_ref: user.id.to_s)
    AgentProposal.create!(thread_key: source.thread_key, channel: "web", channel_ref: app, soul_slug: soul, person: person,
                          source_message: source, kind: kind, capability: capability, params: params, summary: "Open a task",
                          expires_at: 1.day.from_now)
  end

  # The word, stored straight through ProposalConfirm with attrs a caller built:
  # how a word from another channel or thread would reach it.
  def word!(proposal, text, person:, channel: "web", thread_key: proposal.thread_key, channel_ref: proposal.channel_ref)
    attrs = { channel: channel, external_id: SecureRandom.uuid, guild_id: nil, channel_ref: channel_ref,
              thread_key: thread_key, author_ref: person&.user_id.to_s, author_name: "x", person: person,
              content: text, mentions: {}, sent_at: Time.current }
    message, jobs = AgentMessages::ProposalConfirm.new(proposal: proposal, intent: AgentMessages::ProposalConfirm.intent(text))
                                                  .store!(attrs, person: person, source: "test")
    jobs.each { |job, id| job.perform_later(id) }
    message
  end

  def refusal(message) = message.events.find_by(kind: "confirm_refused")&.detail.to_h

  test "the owner's go on their own app's CTO thread confirms the change and queues its run" do
    proposal = proposal!
    go = nil
    assert_enqueued_with(job: AgentProposalJob, args: [ proposal.id ]) { go = ingest(@user, "go") }

    assert_equal %w[completed thread], [ go.status, go.routed_by ]
    assert_equal [ "confirmed", go, "person:#{@person.id}" ], [ proposal.reload.status, proposal.confirm_message, proposal.settled_by ]
  end

  test "an owner of a studio-CTO app confirms on that app's own thread too" do
    studio_owner = User.create!(email: "owner@studio.example", name: "Studio Owner", role: "viewer")
    AppMembership.create!(app: apps(:mcritchie_studio), user: studio_owner)
    proposal = proposal!(user: studio_owner, app: "mcritchie-studio", soul: "avi")

    assert_enqueued_with(job: AgentProposalJob, args: [ proposal.id ]) { ingest(studio_owner, "go", app: "mcritchie-studio") }
    assert_equal "confirmed", proposal.reload.status
  end

  test "the owner's no drops it and their change: goes to the CTO, claimable by the same SQL guard" do
    dropped = proposal!
    no = ingest(@user, "no")
    assert_equal [ "completed", AgentMessages::ProposalConfirm::DROPPED_TEXT ], [ no.status, no.response_text ]
    assert_equal "rejected", dropped.reload.status

    changed = proposal!
    change = ingest(@user, "change: make it the slate page only")
    assert_equal "received", change.status
    assert_equal [ "rejected", "change requested" ], [ changed.reload.status, changed.result["reason"] ]
    assert AgentMessages::Answerers.current.allowed?(@person, message: change), "Ruby answers it"
    assert_includes AgentMessage.claimable(soul: "turf_monster").pluck(:id), change.id, "and the claim's SQL agrees"
  end

  test "an owner may not confirm an ask, or a change the registry would not let them request" do
    ask = proposal!(kind: "ask", capability: "usage", params: {})
    held = nil
    assert_no_enqueued_jobs(only: AgentProposalJob) { held = ingest(@user, "go") }
    assert_equal [ "held", "kind" ], [ held.status, refusal(held)["reason"] ]
    assert_equal AgentMessages::ProposalConfirm::KIND_REFUSED_TEXT, AgentMessages::ProposalConfirm.held_text(refusal(held))
    assert_equal "proposed", ask.reload.status

    ask.settle!("rejected", by: "test")
    bad = proposal!(params: { "title" => "No acceptance" })
    assert_equal "kind", refusal(ingest(@user, "go"))["reason"], "a change missing its required params is out of scope"
    assert_equal "proposed", bad.reload.status
  end

  test "at the app's owner meter cap the word is answered with the cap line from code and nothing runs" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new([ "owner" ], app_owners: { "default_monthly_tokens" => 500 })
    proposal = proposal!
    proposal.source_message.update_columns(run_meta: { "input_tokens" => 500, "audience" => "client" })

    %w[go no].each do |text|
      message = nil
      assert_no_enqueued_jobs(only: AgentProposalJob) do
        assert_enqueued_with(job: AgentMessageReplyJob) { message = ingest(@user, text) }
      end
      assert_equal "completed", message.status
      assert_match(/used its monthly agent allowance/, message.response_text)
      assert_equal [ "usage_cap", text ], refusal(message).values_at("reason", "word")
      assert_includes message.events.pluck(:kind), "usage_capped"
      assert_equal "proposed", proposal.reload.status, "#{text} at the cap changes nothing"
    end

    @turf.update!(cto_cap_lifted_at: Time.current)
    assert_enqueued_with(job: AgentProposalJob, args: [ proposal.id ]) { ingest(@user, "go") }
  end

  test "the owner's word is refused on Discord, by email, and from any thread but the proposal's own" do
    proposal = proposal!
    studio = apps(:mcritchie_studio)
    AppMembership.create!(app: studio, user: @user)

    {
      "Discord" => { channel: "discord" },
      "email" => { channel: "email" },
      "their other app's thread" => { channel_ref: "mcritchie-studio",
                                      thread_key: AgentMessages::WebChat.thread_key("mcritchie-studio", @user.id) },
      "a forged key on their app" => { thread_key: "web:turf-monster:#{@user.id}x" }
    }.each do |label, where|
      message = word!(proposal, "go", person: @person, **where)
      assert_equal [ "held", "not_app_owner" ], [ message.status, refusal(message)["reason"] ], label
    end
    assert_equal "proposed", proposal.reload.status
    assert_no_enqueued_jobs only: AgentProposalJob
  end

  test "another owner of the same app never reaches the proposal; an owner of another app is refused" do
    proposal = proposal!
    co_owner = User.create!(email: "co@turf.example", name: "Co Owner", role: "viewer")
    AppMembership.create!(app: @turf, user: co_owner)
    theirs = ingest(co_owner, "go")
    assert_not_equal proposal.thread_key, theirs.thread_key, "their go lands in their own thread"
    assert_equal "received", theirs.status, "with no proposal there it is an ordinary message"
    co_person = AgentMessages::WebIngest.person_for(co_owner)
    assert_equal "not_app_owner", refusal(word!(proposal, "go", person: co_person))["reason"],
                 "and sent on the owner's key, it is refused"
    theirs_proposal = proposal!(user: co_owner, person: co_person)
    own_key = word!(theirs_proposal, "go", person: @person, thread_key: proposal.thread_key)
    assert_equal "not_app_owner", refusal(own_key)["reason"],
                 "a word on the owner's own thread never confirms a proposal from another thread"
    assert_equal "proposed", theirs_proposal.reload.status

    studio_owner = User.create!(email: "owner@studio.example", name: "Studio Owner", role: "viewer")
    AppMembership.create!(app: apps(:mcritchie_studio), user: studio_owner)
    foreign = proposal!(user: studio_owner)
    held = ingest(studio_owner, "go")
    assert_equal [ "held", "not_app_owner" ], [ held.status, refusal(held)["reason"] ]
    assert_equal AgentMessages::ProposalConfirm::REFUSED_TEXT, AgentMessages::ProposalConfirm.held_text(refusal(held))
    assert_equal %w[proposed proposed], [ proposal.reload.status, foreign.reload.status ]
  end

  test "a held person, a team-role owner, and an owner whose membership is gone are refused" do
    stranger = User.create!(email: "stranger@turf.example", name: "Stranger", role: "viewer")
    unowned = proposal!(user: stranger)
    assert_equal "held", word!(unowned, "go", person: AgentMessages::WebIngest.person_for(stranger)).status

    proposal = proposal!
    @person.set_role!("team")
    assert_equal "held", ingest(@user, "go").status, "team is answered by its role, and confirming is not team's"
    @person.set_role!("public")

    AppMembership.where(user_slug: @user.slug).delete_all
    assert_equal "held", word!(proposal, "go", person: @person.reload).status
    assert_equal %w[proposed proposed], [ unowned.reload.status, proposal.reload.status ]
    assert_no_enqueued_jobs only: AgentProposalJob
  end

  test "the owner role is unchanged: any kind, uncapped" do
    AgentMessages::Answerers.current = AgentMessages::Answerers.new([ "owner" ], app_owners: { "default_monthly_tokens" => 1 })
    ask = AgentProposal.create!(thread_key: "discord:1:1", channel: "discord", guild_id: "1", channel_ref: "1",
                                soul_slug: "turf_monster", person: @alex, kind: "ask", capability: "usage", params: {},
                                summary: "Usage", expires_at: 1.day.from_now)
    attrs = { channel: "discord", external_id: SecureRandom.uuid, guild_id: "1", channel_ref: "1", thread_key: "discord:1:1",
              author_ref: "1", author_name: "Alex", person: @alex, content: "go", mentions: {}, sent_at: Time.current }
    AgentMessages::ProposalConfirm.new(proposal: ask, intent: [ :go ]).store!(attrs, person: @alex, source: "test")
    assert_equal "confirmed", ask.reload.status
  end

  test "what an app owner may confirm, listed: change task only, on every domain's front door" do
    registry = AgentProposal.registry
    registry.domains.each do |key, domain|
      next unless domain.is_a?(Hash) && domain["soul"].present?

      client = AgentMailbox::Audience.new(role: "client", client_domain: key)
      offered = registry.catalog(domain["soul"], audience: client).map { |e| [ e["kind"], e["capability"] ] }
      assert_equal [ %w[change task] ], offered,
                   "#{key}: a client's catalog grew; decide whether its owner may confirm it (ProposalConfirm::OWNER_KINDS)"
    end
    assert_equal %w[change], AgentMessages::ProposalConfirm::OWNER_KINDS
  end
end
