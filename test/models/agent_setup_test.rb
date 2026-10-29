require "test_helper"

# [unit] AgentSetup: a pending agent's manual setup, its ordered steps, who did
# each and when, and the status walk pending → checking → verifying → ready.
class AgentSetupTest < ActiveSupport::TestCase
  APP_ID = "1560516264378507334".freeze

  def open_setup(soul = "mason", **details)
    AgentSetup.open!(agent_slug: soul, kind: "discord_bot", target: "mcritchie-studio", opened_by: "steffon", details: details)
  end

  test "[unit] open! starts pending with the kit's steps in order, none done" do
    setup = open_setup
    assert_equal "pending", setup.status
    assert_equal %w[create_app reset_token paste_token invite done], setup.steps.map(&:key)
    assert_equal [ 1, 2, 3, 4, 5 ], setup.steps.map(&:position)
    assert setup.steps.none?(&:done?)
    assert_equal "create_app", setup.current_step.key
    assert_equal "Mason", setup.detail(:bot_name)
    assert_equal "DISCORD_BOT_TOKEN_MASON", setup.detail(:secret_env)
  end

  test "[unit] one live setup per agent, kind and target; a closed one frees the slot" do
    first = open_setup
    assert_raises(ActiveRecord::RecordNotUnique) { AgentSetup.transaction(requires_new: true) { open_setup } }
    first.close!(by: "steffon")
    assert_equal "pending", open_setup.status
  end

  test "[unit] a step records who ticked it and when, and can be unticked" do
    setup = open_setup
    step = setup.mark_step!("create_app", by: "Alex McRitchie")
    assert_equal "Alex McRitchie", step.done_by
    assert step.done_at
    assert_equal "reset_token", setup.reload.current_step.key

    setup.mark_step!("create_app", by: "Alex McRitchie", done: false)
    refute setup.reload.steps.first.done?
    assert_raises(ActiveRecord::RecordNotFound) { setup.mark_step!("nope", by: "x") }
  end

  test "[unit] Done is blocked until the application id is in, then marks every step and goes to checking" do
    setup = open_setup
    assert_match(/Application ID/, setup.submit_blocker)
    assert_raises(ArgumentError) { setup.submit!(by: "Alex McRitchie") }

    setup.update!(details: setup.details.merge("application_id" => APP_ID))
    assert_nil setup.submit_blocker
    setup.submit!(by: "Alex McRitchie")
    setup.reload
    assert_equal "checking", setup.status
    assert_equal "Alex McRitchie", setup.submitted_by
    assert setup.steps.all?(&:done?)
    assert_match(/checking/, setup.submit_blocker, "Done is not pressed twice")
    assert_raises(ArgumentError) { setup.mark_step!("invite", by: "x") }
  end

  test "[unit] needs_attention reopens Done; ready and closed are finished" do
    setup = open_setup(application_id: APP_ID)
    setup.submit!(by: "Alex McRitchie")
    setup.needs_attention!("The bot is not in the server yet.")
    assert setup.submittable?
    assert setup.open?

    setup.await_verify!("Waiting for Steffon.")
    setup.ready!(by: "steffon")
    assert setup.finished?
    assert_equal [ setup ], AgentSetup.finished.to_a
    assert_empty AgentSetup.open_setups
  end

  test "[unit] details refuse a value shaped like a bot token" do
    setup = open_setup
    setup.details = setup.details.merge("bot_name" => "MTU2MDUxNjI2NDM3ODUwNzMzNA.GxYzAb.abcdefghijklmnopqrstuvwxyz0123")
    refute setup.valid?
    assert_match(/looks like a token/, setup.errors.full_messages.join)
  end

  test "[unit] an unknown kind or status is refused" do
    assert_raises(ArgumentError) { AgentSetup.open!(agent_slug: "mason", kind: "carrier_pigeon", target: "x", opened_by: "s") }
    setup = open_setup
    setup.status = "lost"
    refute setup.valid?
  end

  test "[unit] the status CHECK holds exactly AgentSetup::STATUSES, so a write that skips validations is refused" do
    setup = open_setup
    AgentSetup::STATUSES.each { |status| setup.update_column(:status, status) }
    assert_raises(ActiveRecord::StatementInvalid) { setup.update_column(:status, "lost") }
  end
end
