require "test_helper"

# The Pending agents column of /agents and its writes (AgentsController#index,
# AgentSetupsController). Admin only: a signed-in non-admin gets a 404 from
# every write, and the page itself is behind the wall as it always was.
class AgentSetupsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  APP_ID = "1560516264378507334".freeze
  OP_IDS = { op_account_id: "a" * 26, op_vault_id: "b" * 26, op_item_id: "c" * 26, op_host: "my.1password.com" }.freeze

  def admin = users(:alex)
  def member = @member ||= User.create!(email: "setups-member@example.com", name: "Member")

  def open_setup(soul = "mason", **details)
    AgentSetup.open!(agent_slug: soul, kind: "discord_bot", target: "mcritchie-studio", opened_by: "steffon",
                     details: OP_IDS.merge(details))
  end

  test "[integration] an admin sees the split page: the agents and a Pending agents column of cards" do
    setup = open_setup
    log_in_as(admin)
    get agents_path
    assert_response :success
    assert_select "[data-test='agents-split'][data-layout='split']" do
      assert_select "[data-test='agents-grid'] [data-test='agent-row'][data-agent='mason']" do
        assert_select "[data-test='agent-row-title']", "COO"
      end
      assert_select "[data-test='pending-agents'] [data-test='agent-setup-card'][data-agent='mason'][data-status='pending']#agent-setup-#{setup.id}" do
        assert_select "[data-test='agent-setup-badge']", "Your turn"
        assert_select "[data-test='agent-setup-progress']", "Step 1 of 5"
        assert_select "button[data-test='agent-setup-toggle'][aria-expanded='false'][aria-controls='agent-setup-#{setup.id}-steps']"
        assert_select "tr#agent-setup-#{setup.id}-steps[hidden] [data-test='agent-setup-step']", 5
      end
    end
  end

  test "[component] each Discord step renders its button or copy field, and no secret" do
    setup = open_setup(application_id: APP_ID)
    log_in_as(admin)
    get agents_path
    assert_select "#agent-setup-#{setup.id}" do
      assert_select "[data-key='create_app'][data-state='current']" do
        assert_select "a[data-test='discord-portal-link'][href='https://discord.com/developers/applications'][target='_blank']"
        assert_select "input[data-test='discord-bot-name'][value='Mason'][readonly]"
        assert_select "button[data-test='discord-bot-name-copy'][data-copy-clip='Mason']"
        assert_select "a[data-test='discord-avatar-download']", 0
        assert_select "form[data-test='discord-app-id-form'] input[value='#{APP_ID}']"
      end
      assert_select "[data-key='reset_token']", /Reset Token/
      assert_select "[data-key='paste_token'] a[data-test='op-item-link'][href^='https://start.1password.com/open/i']", "Open discord.mason.agents in 1Password"
      assert_select "[data-key='invite'] a[data-test='discord-invite-link'][href*='client_id=#{APP_ID}'][href*='permissions=274877991936']"
      assert_select "[data-key='done'] form button[data-test='agent-setup-done']", "Done"
    end
    refute_match(/bot-token"?\s*[:=]\s*\S{20,}/, response.body)
  end

  test "[component] the avatar download is the hub's own image, and a card with no item or id says so" do
    Agent.find_by(slug: "alex") || flunk("fixture")
    setup = AgentSetup.open!(agent_slug: "alex", kind: "discord_bot", target: "mcritchie-studio", opened_by: "steffon")
    log_in_as(admin)
    get agents_path
    assert_select "#agent-setup-#{setup.id}" do
      assert_select "a[data-test='discord-avatar-download'][data-agent-avatar-png][href='/agents/alex.webp'][download='alex.png']"
      assert_select "[data-test='op-item-missing']", /discord\.alex\.agents/
      assert_select "[data-test='discord-invite-waiting']"
      assert_select "[data-test='agent-setup-blocker']", /Application ID/
      assert_select "[data-test='agent-setup-done']", 0
    end
  end

  test "[integration] no pending agent shows the empty state; finished ones fold under Done" do
    done = open_setup(application_id: APP_ID)
    done.submit!(by: "Alex McRitchie")
    done.ready!(by: "steffon")
    log_in_as(admin)
    get agents_path
    assert_select "[data-test='pending-agents-empty']", /bin\/agent-setup open discord/
    assert_select "details[data-test='pending-agents-finished'] [data-test='finished-setup'][data-status='ready']", 1
  end

  test "[integration] saving the application id, ticking a step, and Done enqueues the verify job" do
    setup = open_setup
    log_in_as(admin)

    patch agent_setup_path(setup), params: { agent_setup: { application_id: "nope" } }
    assert_redirected_to agents_path(open: setup.id, anchor: "agent-setup-#{setup.id}")
    assert_match(/not an Application ID/, flash[:alert])
    assert_nil setup.reload.detail(:application_id)

    patch agent_setup_path(setup), params: { agent_setup: { application_id: " #{APP_ID} " } }
    assert_equal APP_ID, setup.reload.detail(:application_id)

    post agent_setup_step_path(setup, "create_app")
    assert_equal admin.name, setup.reload.steps.first.done_by

    assert_enqueued_with(job: AgentSetupCheckJob, args: [ setup.id ]) do
      post agent_setup_done_path(setup)
    end
    setup.reload
    assert_equal "checking", setup.status
    assert setup.steps.all?(&:done?)

    get agents_path
    assert_select "#agent-setup-#{setup.id}[data-status='checking'] [data-test='agent-setup-badge']", "Checking"
    assert_select "#agent-setup-#{setup.id} [data-test='agent-setup-done']", 0
  end

  # Regression (Carl, pending-agents-page): the step write was the one write
  # here with no rescue_and_log, so a failed tick left no ErrorLog on the card.
  test "[integration] a failed step write is logged against the card" do
    setup = open_setup
    log_in_as(admin)
    AgentSetup.alias_method :__real_mark_step!, :mark_step!
    AgentSetup.define_method(:mark_step!) { |*, **| raise ActiveRecord::StatementInvalid, "simulated write failure" }
    begin
      assert_difference -> { ErrorLog.where(target_type: "AgentSetup", target_id: setup.id).count }, 1 do
        post agent_setup_step_path(setup, "create_app")
      rescue ActiveRecord::StatementInvalid
        nil # re-raised by rescue_and_log after it logs; how the app answers is the global handler's
      end
    ensure
      AgentSetup.alias_method :mark_step!, :__real_mark_step!
      AgentSetup.remove_method :__real_mark_step!
    end
    assert_nil setup.reload.steps.first.done_at
  end

  test "[integration] a step on a card past Alex McRitchie's turn is refused with its status and logs nothing" do
    setup = open_setup(application_id: APP_ID)
    setup.submit!(by: "Alex McRitchie")
    setup.await_verify!("Waiting for Steffon.")
    log_in_as(admin)
    assert_no_difference -> { ErrorLog.count } do
      post agent_setup_step_path(setup, "create_app"), params: { done: "0" }
    end
    assert_redirected_to agents_path(open: setup.id, anchor: "agent-setup-#{setup.id}")
    assert_equal "This setup is verifying.", flash[:alert]
    assert setup.reload.steps.first.done?, "the tick stands"
  end

  test "[integration] the row an action came back to is served open; the others stay collapsed" do
    first = open_setup
    second = open_setup("mack")
    log_in_as(admin)
    get agents_path(open: second.id)
    assert_select "tr#agent-setup-#{second.id}-steps:not([hidden])"
    assert_select "#agent-setup-#{second.id} [data-test='agent-setup-toggle'][aria-expanded='true']", "Hide for Mack"
    assert_select "tr#agent-setup-#{first.id}-steps[hidden]"
  end

  test "[integration] waiting for Steffon is shown honestly, with nothing left to press" do
    setup = open_setup(application_id: APP_ID)
    setup.submit!(by: "Alex McRitchie")
    setup.await_verify!("The bot is in McRitchie Studio. Waiting for Steffon to verify the token and install it as DISCORD_BOT_TOKEN_MASON.")
    log_in_as(admin)
    get agents_path
    assert_select "#agent-setup-#{setup.id}" do
      assert_select "[data-test='agent-setup-badge']", "Waiting for Steffon to verify"
      assert_select "[data-test='agent-setup-reason']", /Waiting for Steffon/
      assert_select "[data-test='agent-setup-waiting']", /Nothing more for you/
      assert_select "[data-test='agent-setup-step-tick'], [data-test='agent-setup-step-undo'], [data-test='agent-setup-done']", 0
    end
  end

  test "[integration] Done without the application id is refused and enqueues nothing" do
    setup = open_setup
    log_in_as(admin)
    assert_no_enqueued_jobs(only: AgentSetupCheckJob) { post agent_setup_done_path(setup) }
    assert_match(/Application ID/, flash[:alert])
    assert_equal "pending", setup.reload.status
  end

  test "[integration] a signed-in non-admin gets a 404 from every write; a visitor is sent to sign in" do
    setup = open_setup
    log_in_as(member)
    patch agent_setup_path(setup), params: { agent_setup: { application_id: APP_ID } }
    assert_response :not_found
    post agent_setup_step_path(setup, "create_app")
    assert_response :not_found
    post agent_setup_done_path(setup)
    assert_response :not_found
    assert_nil setup.reload.detail(:application_id)
    assert setup.steps.none?(&:done?)

    get agents_path
    assert_response :redirect, "the agents page stays behind the wall, as before"
  end

  test "[integration] a visitor never reaches the writes" do
    setup = open_setup
    post agent_setup_done_path(setup)
    assert_response :redirect
    assert_equal "pending", setup.reload.status
  end

  # Alex McRitchie 2026-10-28: "is a link in the admin sidebar? That's important so I can find this page".
  test "[integration] the admin sidebar links the agents page and names its pending setups" do
    page = Navigation.registry.page(:agents)
    assert_equal "agents#index", page.action_id
    assert_match(/pending setups/, page.desc)
    assert(Navigation.registry.sidebar("general").any? { |section| section.pages.map(&:key).include?("agents") },
           "the Studio section lists the agents page")
  end
end
