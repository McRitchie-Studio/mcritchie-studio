# The writes behind the Pending agents column of /agents (AgentSetup; SOP
# docs/agents/agents/steffon/sops/agent-onboarding.md): Alex McRitchie pastes
# the public Application ID, ticks a step, and presses Done.
#
# ADMIN ONLY, AND A 404 FOR EVERYONE ELSE. The actions are listed in
# AdminWall::SIGNED_IN only so a signed-in non-admin reaches this controller and
# gets the same 404 as a missing card, never a redirect that says the address
# exists; a visitor still meets the wall's sign-in. No action takes, stores or
# renders a secret: the token goes from the Developer Portal to 1Password by
# Alex McRitchie's own paste.
class AgentSetupsController < ApplicationController
  before_action :require_admin_or_404
  before_action :load_setup

  # PATCH /agents/pending/:id — the Application ID (public: the portal shows it
  # on General Information, and it is the invite's client_id).
  def update
    app_id = params.dig(:agent_setup, :application_id).to_s.strip
    unless app_id.match?(AgentSetups::DiscordBotKit::SNOWFLAKE)
      return back_to_card(alert: "That is not an Application ID: copy the 17 to 20 digit number from General Information.")
    end
    return back_to_card(alert: @setup.submit_blocker) unless @setup.submittable?

    rescue_and_log(target: @setup) { @setup.update!(details: @setup.details.merge("application_id" => app_id)) }
    back_to_card(notice: "Application ID saved; the Invite button is ready.")
  end

  # POST /agents/pending/:id/steps/:key — tick (or, with done=0, untick) one step.
  def step
    @setup.mark_step!(params[:key], by: actor, done: params[:done] != "0")
    back_to_card
  rescue ArgumentError => e
    back_to_card(alert: e.message)
  end

  # POST /agents/pending/:id/done — every step marked, the hub's check queued.
  def submit
    if (blocker = @setup.submit_blocker)
      return back_to_card(alert: blocker)
    end

    rescue_and_log(target: @setup) do
      @setup.submit!(by: actor)
      AgentSetupCheckJob.perform_later(@setup.id)
    end
    back_to_card(notice: "Done: the hub is checking the bot, then it waits for Steffon to verify and install it.")
  end

  private

  def require_admin_or_404
    raise ActiveRecord::RecordNotFound, "no such setup" unless admin?
  end

  def load_setup
    @setup = AgentSetup.includes(:steps, :agent).find(params[:id])
  end

  def actor = current_user.name.presence || current_user.email

  def back_to_card(**flash_message)
    redirect_to agents_path(open: @setup.id, anchor: "agent-setup-#{@setup.id}"), **flash_message
  end
end
