require "test_helper"
require_relative "../../support/agent_email_fixtures"

# [unit] An email after desk capture (AgentMessages::EmailIngest): which become
# agent messages, whose audience they carry, how they thread, the go confirm by
# email, the loop guards and the per-thread rate limit.
class EmailIngestTest < ActiveSupport::TestCase
  include AgentEmailFixtures
  include ActiveJob::TestHelper

  setup do
    @alex = AgentPerson.seed_owner!
  end

  def ingest(raw, now: Time.current) = AgentMessages::EmailIngest.new(now: now).call(raw)

  test "the owner's verified mail to avi@ is a received email row for Avi, from the owner's person" do
    message = ingest(agent_email)
    assert_equal %w[email avi alias received], [ message.channel, message.soul_slug, message.routed_by, message.status ]
    assert_equal @alex, message.person, "alex@mcritchie.studio is the owner's email identity"
    assert_equal "CAfixture-owner-to-avi-0001@mail.gmail.com", message.external_id
    assert_equal "email:CAfixture-owner-to-avi-0001@mail.gmail.com", message.thread_key
    assert_equal "avi@mcritchie.studio", message.channel_ref
    assert_nil message.guild_id
    assert_match(/\ASubject: What is on QA\?\n\nWhat is on QA right now/, message.content)
    assert_equal true, message.envelope.dig("trust", "verified")
    assert_equal message, AgentMessage.claimable(soul: "avi").first
  end

  test "a repeat of the same Message-ID stores nothing new" do
    first = ingest(agent_email)
    assert_no_difference -> { AgentMessage.count } do
      assert_equal first, ingest(agent_email)
    end
  end

  test "mail that is not for a CTO stays a desk capture: no row" do
    assert_nil ingest(agent_email(to: "Team <team@mcritchie.studio>", subject: "Hi Team", body: "Hi Team how are you!"))
    assert_equal 0, AgentMessage.count
  end

  test "a forged alex@ with a forged lower amazonses.com pass is held as the public, with no person" do
    raw = agent_email(top_result: ses_result(dkim: "dkim=fail header.i=@mcritchie.studio",
                                             dmarc: "dmarc=fail header.from=mcritchie.studio"),
                      sender_headers: [ FORGED_PASS ], message_id: "forged-1@evil.example")
    message = ingest(raw)
    assert_equal %w[held avi], [ message.status, message.soul_slug ]
    assert_nil message.person
    assert_nil message.author_ref
    assert_match(/unverified/, message.author_name)
    held = message.events.find_by(kind: "held")
    assert_match(/sender not verified/, held.detail["reason"])
    assert_nil AgentMessage.claimable(soul: "avi").first, "a held, person-less row is never claimed"
  end

  test "a verified stranger is their own public person, held" do
    raw = agent_email(from: "Bea <bea@example.com>", message_id: "bea-1@example.com",
                      top_result: ses_result(dkim: "dkim=pass header.i=@example.com", dmarc: "dmarc=pass header.from=example.com"))
    message = ingest(raw)
    assert_equal "held", message.status
    assert_equal "public", message.person.role
    refute_equal @alex, message.person
  end

  test "a reply continues the thread: same key, same soul, same channel ref" do
    first = ingest(agent_email)
    reply = ingest(agent_email(to: "team@mcritchie.studio", subject: "Re: What is on QA?", body: "And release?",
                               message_id: "reply-2@mail.gmail.com", in_reply_to: "agentmsg-1.x@mcritchie.studio",
                               references: [ first.external_id, "agentmsg-1.x@mcritchie.studio" ]))
    assert_equal [ first.thread_key, "avi", "thread", "avi@mcritchie.studio" ],
                 [ reply.thread_key, reply.soul_slug, reply.routed_by, reply.channel_ref ]
  end

  test "a fresh thread is keyed by its References root, then In-Reply-To, then its own id" do
    by_refs = ingest(agent_email(message_id: "m-1@x", in_reply_to: "p@x", references: %w[root@x p@x]))
    assert_equal "email:root@x", by_refs.thread_key
    by_irt = ingest(agent_email(message_id: "m-2@x", in_reply_to: "only-parent@x"))
    assert_equal "email:only-parent@x", by_irt.thread_key
  end

  test "the loop guards store nothing" do
    assert_nil ingest(agent_email(from: "Avi <avi@mcritchie.studio>", message_id: "cto-1@x",
                                  top_result: ses_result))
    assert_nil ingest(agent_email(message_id: "auto-1@x", sender_headers: [ "Auto-Submitted: auto-replied" ]))
    assert_nil ingest(agent_email(message_id: "own-1@x", sender_headers: [ "X-McRitchie-Agent: avi" ]))
    assert_equal 0, AgentMessage.count
  end

  test "past the per-thread rate limit a row is held with a rate_limited event" do
    limit = AgentMessages::EmailIngest::RATE_LIMIT
    first = ingest(agent_email)
    (limit - 1).times do |i|
      ingest(agent_email(to: "team@mcritchie.studio", message_id: "r-#{i}@x", references: [ first.external_id ]))
    end
    over = ingest(agent_email(to: "team@mcritchie.studio", message_id: "r-over@x", references: [ first.external_id ]))
    assert_equal "held", over.status
    assert over.events.exists?(kind: "rate_limited")
    later = ingest(agent_email(to: "team@mcritchie.studio", message_id: "r-later@x", references: [ first.external_id ]),
                   now: 2.hours.from_now)
    assert_equal "received", later.status, "the window rolls"
  end

  # --- proposal confirm by email -------------------------------------------------

  def proposal_for(message)
    AgentProposal.create!(thread_key: message.thread_key, channel: "email", guild_id: nil,
                          channel_ref: message.channel_ref, soul_slug: "avi", person: @alex, source_message: message,
                          kind: "ask", capability: "board_status", params: {}, summary: "Count the board",
                          expires_at: 24.hours.from_now)
  end

  def go_reply(source, body:, message_id:, **opts)
    agent_email(to: "team@mcritchie.studio", subject: "Re: What is on QA?", message_id: message_id,
                in_reply_to: "agentmsg-#{source.id}.x@mcritchie.studio",
                references: [ source.external_id, "agentmsg-#{source.id}.x@mcritchie.studio" ],
                body: "#{body}\r\n\r\nOn Fri, Oct 16, 2026 at 1:20 PM Avi <avi@mcritchie.studio> wrote:\r\n> Reply go to run this",
                **opts)
  end

  test "the owner's in-thread go confirms the pending proposal and queues the run, never a model" do
    source = ingest(agent_email)
    proposal = proposal_for(source)
    message = ingest(go_reply(source, body: "go", message_id: "go-1@mail.gmail.com"))
    assert_equal %w[completed thread], [ message.status, message.routed_by ]
    assert_equal "confirmed", proposal.reload.status
    assert_equal message, proposal.confirm_message
    assert_enqueued_with(job: AgentProposalJob, args: [ proposal.id ])
  end

  test "no drops it by email" do
    source = ingest(agent_email)
    proposal = proposal_for(source)
    message = ingest(go_reply(source, body: "No", message_id: "no-1@mail.gmail.com"))
    assert_equal "rejected", proposal.reload.status
    assert_equal AgentMessages::ProposalConfirm::DROPPED_TEXT, message.response_text
  end

  test "a forged go is held with confirm_refused; nothing runs" do
    source = ingest(agent_email)
    proposal = proposal_for(source)
    forged = go_reply(source, body: "go", message_id: "go-forged@evil.example",
                              top_result: ses_result(dkim: "dkim=fail header.i=@mcritchie.studio",
                                                     dmarc: "dmarc=fail header.from=mcritchie.studio"),
                              sender_headers: [ FORGED_PASS ])
    message = ingest(forged)
    assert_equal "held", message.status
    assert message.events.exists?(kind: "confirm_refused")
    assert_equal "proposed", proposal.reload.status
    assert_no_enqueued_jobs only: [ AgentProposalJob, AgentMessageReplyJob ]
  end

  test "a go outside the proposal's thread confirms nothing" do
    source = ingest(agent_email)
    proposal = proposal_for(source)
    elsewhere = agent_email(to: "avi@mcritchie.studio", subject: "go", body: "go", message_id: "go-elsewhere@x")
    message = ingest(elsewhere)
    assert_equal "received", message.status, "it is routed as an ordinary message"
    assert_equal "proposed", proposal.reload.status
  end
end
