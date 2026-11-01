require "test_helper"
require_relative "../support/client_cto_fixtures"

# [integration] The free tier's CTO chat budget end to end, shipped config
# (task free-budget-meter; Alex McRitchie, 2026-10-19): an owner of a /build app (Vibe,
# 25,000 tokens a month) writes through /applications/:slug/chat, the
# dispatcher's claim and complete, and the reply job's delivery, which pushes
# the updated meter ("1,840 of 25,000 tokens this month") to the open page.
# At the cap the next message is answered from code with the cap line and the
# plans link: it is never claimable, so no model runs, and its delivery redraws
# the meter as capped, with the upgrade link.
class FreeBudgetMeterTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper
  include ClientCtoFixtures

  # Day one of October, after the 1am Denver reset: one answer projects past the
  # allowance, so the upgrade suggestion always renders. The clock steps a minute
  # after each answer, because the meter counts [period start, now).
  setup do
    travel_to Time.find_zone("America/Denver").local(2026, 10, 1, 9)
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @client_app = client_app!
    @owner = User.create!(email: "pat@example.com", name: "Pat", role: "viewer")
    AppMembership.create!(app: @client_app, user: @owner)
    @stream = AgentMessages::WebChat.stream_name(@client_app.slug, @owner.id)
  end

  teardown { AgentMessages::Answerers.reset! }

  def send_chat(text)
    post chat_application_path(@client_app.slug), params: { cto_chat: { text: text, client_id: SecureRandom.hex(8) } }, as: :turbo_stream
    assert_response :success
    AgentMessage.where(channel: "web", channel_ref: @client_app.slug).order(:id).last
  end

  def claim_one = AgentMessage.claim!(soul: AppCto::SOUL, worker: "w1").message

  def run_summary(tokens) = { run_meta: { "input_tokens" => tokens - 40, "output_tokens" => 40, "cache_read_tokens" => 0,
                                  "cache_creation_tokens" => 0, "model" => "m" } }

  # The meter broadcasts the stream carried, as the HTML the browser receives.
  def meter_broadcasts
    broadcasts(@stream).map { |payload| JSON.parse(payload) }
                       .select { |html| html.include?(%(target="#{AgentMessages::WebChat::METER_TARGET}")) }
  end

  test "[integration] a CTO reply broadcasts the updated meter to the owner's open card" do
    log_in_as(@owner)
    get chat_application_path(@client_app.slug)
    assert_select "#cto-chat-meter [data-test='usage-meter-line']", text: /0% used\s+Resets \w{3} \d+ at 1am M[SD]T\s+0 \/ 25,000/

    message = send_chat("How do I add a booking form?")
    assert_equal "received", message.status, "an owner under the cap is answered by the model"
    claimed = claim_one
    assert_equal message, claimed
    claimed.complete!(worker: "w1", response_text: "Add a form on the home page.", run: run_summary(1_840))
    travel 1.minute
    assert_equal "client", claimed.reload.run_meta["audience"], "the owner's answer is metered as a client's"

    perform_enqueued_jobs(only: AgentMessageReplyJob) { AgentMessageReplyJob.perform_later(claimed.id) }
    meter = meter_broadcasts.last
    assert meter, "the reply's delivery pushed the meter"
    assert_includes meter, %(action="update")
    assert_match(/data-test="usage-meter-percent">7&#37; used</, meter)
    assert_match(/data-test="usage-meter-tokens">1,840 \/ 25,000</, meter)
    assert_includes meter, %(data-state="ok")
    assert_includes meter, %(aria-valuenow="7")
    # The meter counts tokens, never dollars. The upgrade suggestion is the one
    # line that may name a price ("Builder ($100/month) raises it."): early in a
    # month one day's spend projects past the allowance and it appears, which
    # turned this assertion red on 2026-11-01. Judge everything but that line.
    assert_match(%r{data-test="usage-suggestion"[^>]*>[^<]*\$}, meter, "day one renders the priced suggestion")
    usage = meter.sub(%r{<p [^>]*data-test="usage-suggestion".*?</p>}m, "")
    assert_not_includes usage, "$", "tokens, never dollars"
  end

  test "[integration] at the cap the owner gets the cap line and the plans link from code, with no dispatch" do
    log_in_as(@owner)
    spent = send_chat("first")
    claim_one.complete!(worker: "w1", response_text: "Sure.", run: run_summary(25_000))
    travel 1.minute
    assert_equal 25_000, AgentUsage.owner_meter(@client_app).used

    capped = nil
    assert_no_difference -> { AgentMessage.where(status: "claimed").count } do
      capped = send_chat("one more?")
    end
    refute_equal spent, capped
    capped.reload
    assert_equal [ "completed", "usage cap" ], [ capped.status, capped.action_summary ]
    assert_match(/\AThis app has used its monthly agent allowance, so I can't answer this one\./, capped.response_text)
    assert_includes capped.response_text, "[Upgrade your plan](http://www.example.com/packages)"
    assert_nil capped.claimed_by, "no worker ever held it"
    assert_empty AgentMessage.claimable(soul: AppCto::SOUL).where(id: capped.id), "the dispatcher cannot claim it"
    assert_nil AgentMessage.claim!(soul: AppCto::SOUL, worker: "w2").message, "nothing is left for a model to answer"

    perform_enqueued_jobs(only: AgentMessageReplyJob)
    assert_equal "posted", capped.reload.reply_status
    meter = meter_broadcasts.last
    assert_includes meter, %(data-state="capped")
    assert_includes meter, %(href="/packages")
    assert_includes meter, "usage-upgrade-link"

    get chat_application_path(@client_app.slug)
    assert_select "[data-test='usage-cap-note'] a[data-test='usage-upgrade-link'][href='/packages']"
    assert_select "[data-test='cto-chat-turn'] a[href='http://www.example.com/packages']", minimum: 1
  end
end
