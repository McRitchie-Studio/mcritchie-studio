require "test_helper"
require_relative "../support/agent_email_fixtures"

# [integration] Email end to end (docs/agents/system/agent-message-loop.md,
# "Email"): a raw MIME owner email to avi@ arrives through the Resend inbound
# job, is captured on the desk AND becomes an email agent message, is claimed
# and answered, and the answer is sent through the hub's Resend path (the
# Studio::Email outbox, then Resend's ActionMailer delivery with
# Resend::Emails.send stubbed) as Avi, Reply-To team@, threaded, plain text.
# A forged sender is held and never answered.
class AgentEmailLoopTest < ActiveJob::TestCase
  include AgentEmailFixtures

  setup do
    @alex = AgentPerson.seed_owner!
    @capture = Studio.local_email_capture
    Studio.local_email_capture = false
  end

  teardown do
    Studio.local_email_capture = @capture
  end

  def receive(raw, email_id)
    originals = { fetch_received: DeskCapture::ResendClient.method(:fetch_received),
                  fetch_url: DeskCapture::ResendClient.method(:fetch_url), store: DeskCapture.method(:store) }
    DeskCapture::ResendClient.define_singleton_method(:fetch_received) { |_id| { "raw" => { "download_url" => "https://signed.example/raw" } } }
    DeskCapture::ResendClient.define_singleton_method(:fetch_url) { |_url| raw }
    DeskCapture.define_singleton_method(:store) { |key, _body, **| key }
    DeskCaptureResendIngestJob.perform_now(email_id)
  ensure
    DeskCapture::ResendClient.define_singleton_method(:fetch_received, originals[:fetch_received])
    DeskCapture::ResendClient.define_singleton_method(:fetch_url, originals[:fetch_url])
    DeskCapture.define_singleton_method(:store, originals[:store])
  end

  # Resend's own ActionMailer delivery, with its one network call captured.
  def with_resend(sent)
    previous_method = ActionMailer::Base.delivery_method
    previous_key = Resend.api_key
    original = Resend::Emails.method(:send)
    Resend.api_key = "re_test_key"
    ActionMailer::Base.delivery_method = :resend
    Resend::Emails.define_singleton_method(:send) do |params, options: {}|
      sent << { params: params, options: options }
      { id: "resend-email-#{sent.size}" }
    end
    yield
  ensure
    Resend::Emails.define_singleton_method(:send, original)
    ActionMailer::Base.delivery_method = previous_method
    Resend.api_key = previous_key
  end

  test "an owner email to avi@ becomes an agent message and Avi's answer is mailed back, threaded" do
    raw = File.binread(Rails.root.join("test/fixtures/files/agent_email/owner_to_avi.eml"))
    receive(raw, "re_avi_1")

    item = DeskCaptureItem.find_by!(s3_key: "resend/re_avi_1.eml")
    message = AgentMessage.find_by!(channel: "email")
    assert_equal item.id, message.envelope["desk_item_id"], "the desk keeps its capture too"
    assert_equal [ "avi", "received", @alex ], [ message.soul_slug, message.status, message.person ]

    claim = AgentMessage.claim!(soul: "avi", worker: "w1")
    assert_equal message, claim.message
    assert_equal "not_typing_channel", message.reload.typing_refusal(worker: "w1"), "email has no typing pulse"
    message.complete!(worker: "w1", response_text: "Two tasks are on QA. **Nothing** is blocked.")

    sent = []
    with_resend(sent) do
      perform_enqueued_jobs(only: AgentMessageReplyJob)
      perform_enqueued_jobs(only: Studio::EmailDeliveryJob)
      # A retried reply job sends nothing again.
      AgentMessageReplyJob.perform_now(message.id)
      perform_enqueued_jobs(only: Studio::EmailDeliveryJob)
    end

    assert_equal 1, sent.size, "one send, however often the reply job runs"
    params = sent.first[:params]
    assert_equal "Avi <avi@mcritchie.studio>", params[:from]
    assert_equal [ "alex@mcritchie.studio" ], params[:to]
    assert_equal [ "team@mcritchie.studio" ], Array(params[:reply_to])
    assert_equal "Re: What is on QA?", params[:subject]
    assert_equal "<CAfixture-owner-to-avi-0001@mail.gmail.com>", params[:headers]["In-Reply-To"]
    assert_equal "<CAfixture-owner-to-avi-0001@mail.gmail.com>", params[:headers]["References"]
    assert_equal "auto-replied", params[:headers]["Auto-Submitted"]
    assert_equal "avi", params[:headers]["X-McRitchie-Agent"]
    assert_nil params[:html], "plain text only"
    assert_includes params[:text], "Two tasks are on QA. Nothing is blocked."
    assert_equal({ idempotency_key: "test:app:agentmsg-#{message.id}" }, sent.first[:options].transform_keys(&:to_sym),
                 "the key is scoped to the environment and host, so QA and production never collide")

    message.reload
    assert_equal "posted", message.reply_status
    assert_equal AgentReplyMailer.reply_message_id(message), message.reply_external_id
    assert message.events.exists?(kind: "reply_posted")

    # Alex replies to the answer (Reply-To brings it to team@): it joins the thread.
    reply = agent_email(to: "team@mcritchie.studio", subject: "Re: What is on QA?", body: "Thanks. And next?",
                        message_id: "reply-after@mail.gmail.com", in_reply_to: message.reply_external_id,
                        references: [ message.external_id, message.reply_external_id ])
    receive(reply, "re_avi_2")
    follow = AgentMessage.find_by!(external_id: "reply-after@mail.gmail.com")
    assert_equal [ message.thread_key, "avi", "received" ], [ follow.thread_key, follow.soul_slug, follow.status ]
  end

  test "a forged sender is held, never claimed and never answered; its desk capture stands" do
    forged = agent_email(top_result: ses_result(dkim: "dkim=fail header.i=@mcritchie.studio",
                                                dmarc: "dmarc=fail header.from=mcritchie.studio"),
                         sender_headers: [ FORGED_FOLDED ], message_id: "forged-int@evil.example")
    receive(forged, "re_forged_1")

    assert DeskCaptureItem.exists?(s3_key: "resend/re_forged_1.eml")
    message = AgentMessage.find_by!(external_id: "forged-int@evil.example")
    assert_equal "held", message.status
    assert_nil message.person
    assert_nil AgentMessage.claim!(soul: "avi", worker: "w1").message
    assert_no_enqueued_jobs only: [ AgentMessageReplyJob, Studio::EmailDeliveryJob ]
  end

  test "an admin-released unverified email is still never mailed to its unproven From" do
    forged = agent_email(top_result: nil, message_id: "unverified-release@x")
    receive(forged, "re_unverified_1")
    message = AgentMessage.find_by!(external_id: "unverified-release@x")
    message.release_hold!(actor: "admin")
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "Hello.")

    perform_enqueued_jobs(only: AgentMessageReplyJob)
    assert_equal "skipped", message.reload.reply_status
    assert_equal 0, Studio::EmailDelivery.count
  end

  test "an email ingest failure never undoes the desk capture" do
    original = AgentMessages::EmailIngest.instance_method(:call)
    AgentMessages::EmailIngest.define_method(:call) { |*, **| raise "boom" }
    receive(File.binread(Rails.root.join("test/fixtures/files/agent_email/owner_to_avi.eml")), "re_boom")
    assert DeskCaptureItem.exists?(s3_key: "resend/re_boom.eml")
    assert_equal 0, AgentMessage.count
  ensure
    AgentMessages::EmailIngest.define_method(:call, original)
  end
end
