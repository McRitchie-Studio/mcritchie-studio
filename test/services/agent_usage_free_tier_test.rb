require "test_helper"
require_relative "../support/agent_message_fixtures"
require_relative "../support/client_cto_fixtures"

# [unit] The free tier's CTO chat budget (task free-budget-meter; Alex McRitchie,
# 2026-10-19: "very small and updated after each message returned"), with the
# SHIPPED config, nothing stubbed: a /build app is on Vibe, and Vibe's
# cto_monthly_tokens (25,000) is the owner's cap, not the 1,000,000 default;
# the meter's math and its boundary at exactly 25,000; the gate stops there;
# the first version's build never counts; and the cap line links the plans page.
class AgentUsageFreeTierTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ClientCtoFixtures

  NOW = Time.zone.parse("2026-10-16 12:00 MDT")

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    @app = client_app!
    @user = User.create!(email: "pat@example.com", name: "Pat", role: "viewer")
    AppMembership.create!(app: @app, user: @user)
    @person = AgentMessages::WebIngest.person_for(@user)
  end

  teardown { AgentMessages::Answerers.reset! }

  def web_row!(status: "completed", **attrs)
    agent_message!(soul: AppCto::SOUL, channel: "web", guild_id: nil, channel_ref: @app.slug,
                   thread_key: AgentMessages::WebChat.thread_key(@app.slug, @user.id), author_ref: @user.id.to_s,
                   person: @person, content: "hi", status: status, routed_by: "chat", **attrs)
  end

  # A completed CTO answer to the owner, as the board stamps it (audience client).
  def answered!(tokens, at: NOW - 1.hour, **attrs)
    web_row!(completed_at: at, **attrs).tap do |m|
      m.update_columns(run_meta: { "input_tokens" => tokens - 40, "output_tokens" => 40, "cache_read_tokens" => 0,
                                   "cache_creation_tokens" => 0, "audience" => "client" })
    end
  end

  test "a /build app starts on Vibe, and the owner's cap is Vibe's 25,000, not the 1,000,000 default" do
    assert_equal "vibe", AppRequest.new.tier, "the /build request's default tier"
    assert_equal 25_000, WorkspacePackage.find("vibe").cto_monthly_tokens
    assert_equal 1_000_000, AgentMessages::Answerers.current.app_owners.default_monthly_tokens, "the default stands for others"

    meter = AgentUsage.owner_meter(@app, now: NOW)
    assert_equal [ 25_000, 0, :ok ], [ meter.allowance, meter.used, meter.state ]
    chat = AgentUsage.chat_meter(@app, user: @user, soul: AppCto::SOUL, now: NOW)
    assert_equal 25_000, chat.allowance, "the chat page shows the owner the same cap they are held to"
  end

  test "meter math: used, remaining and percent against the small cap" do
    answered!(1_000)
    answered!(840)
    meter = AgentUsage.owner_meter(@app, now: NOW)
    assert_equal [ 1_840, 23_160, 7, :ok ], [ meter.used, meter.remaining, meter.percent, meter.state ]
  end

  test "the cap boundary: one token short is a warning, exactly 25,000 is capped and the gate stops" do
    answered!(24_999)
    meter = AgentUsage.owner_meter(@app, now: NOW)
    assert_equal :warn, meter.state
    assert_equal :warn, AgentUsage.gate(web_row!(status: "received"), now: NOW).state

    answered!(1)
    meter = AgentUsage.owner_meter(@app, now: NOW)
    assert_equal [ 25_000, 0, :capped ], [ meter.used, meter.remaining, meter.state ]
    assert_equal :stop, AgentUsage.gate(web_row!(status: "received"), now: NOW).state
  end

  test "a paid tier keeps its blank allowance: the owner falls back to the 1,000,000 default" do
    @app.update!(package_tier: "builder")
    assert_equal 1_000_000, AgentUsage.owner_meter(@app, now: NOW).allowance
  end

  test "the first version's build never counts: progress lines are skipped even if one carried tokens" do
    # The request AppLaunch leaves behind (its subdomain is the app's, which the
    # create-time name check refuses once the App exists, so it is saved as is).
    Task.create!(title: "Launch Pawsome", slug: "launch-pawsome")
    request = AppRequest.new(user: @user, subdomain: @app.slug, prompt: "A booking page", status: "building",
                             task_slug: "launch-pawsome", tier: "vibe", token: SecureRandom.hex(16))
    request.save!(validate: false)
    line = ClientBuilds.progress!(request.task_slug, kind: "started", run: "r1", now: NOW - 2.hours)
    assert_equal ClientBuilds::VIA, line.envelope["via"]
    # The worst case: a progress row stamped like a metered answer, with tokens.
    line.update_columns(run_meta: { "input_tokens" => 20_000, "audience" => "client" })
    answered!(500)

    meter = AgentUsage.owner_meter(@app, now: NOW)
    assert_equal 500, meter.used, "the build's line is no answer and spends nothing"
    assert_equal 1, meter.totals.messages
  end

  test "the cap line is code with an absolute link to the plans page" do
    answered!(25_000)
    reply = AgentUsage.cap_reply(AgentUsage.owner_meter(@app, now: NOW))
    assert_match(/\AThis app has used its monthly agent allowance, so I can't answer this one\. It resets Nov 1 at 1am MST\./, reply)
    assert_includes reply, "[Upgrade your plan](http://www.example.com/packages)"
    assert_includes reply, "Builder ($100/month) raises it.", "the next tier up is named, at its configured price"
    assert_equal "I can't answer right now. Please try again after Nov 1 at 1am MST.",
                 AgentUsage.cap_reply(AgentUsage.owner_meter(@app, now: NOW), audience: "public"), "the public reads no upgrade"
  end
end
