# The floor alert's escalation to a person (AgentMessages::FloorAlert#escalate;
# docs/agents/agents/steffon/sops/agent-dispatcher.md, "Alerts"). Sent through
# the hub's outbox (Studio::Email.deliver) to config/agent_routes.yml
# `floor.escalation_email`, at most once per episode per state:
#
#   escalated  an incident has stayed open ESCALATE_AFTER, or its episode flapped
#              FLAP_COUNT times within FLAP_WINDOW
#   recovered  the episode has been quiet (nothing open) for QUIET
#
# Plain text. Arguments are ids and strings: the outbox serializes them.
class AgentFloorMailer < ApplicationMailer
  SOP_PATH = "docs/agents/agents/steffon/sops/agent-dispatcher.md".freeze
  SOP_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/blob/main/#{SOP_PATH}".freeze

  # +reason+ is "open" or "flapping".
  def escalated(root_id, reason, to)
    load_episode(root_id)
    @reason = reason
    subject = reason == "flapping" ? "flapping, #{@opens} since #{@since}" : "open #{@open_minutes} min"
    mail(to: to, subject: "Floor alert: #{@label} (#{subject})") { |format| format.text }
  end

  def recovered(root_id, to)
    load_episode(root_id)
    mail(to: to, subject: "Floor clear: #{@label}") { |format| format.text }
  end

  private

  def load_episode(root_id)
    @root = AgentMailboxIncident.find(root_id)
    @incidents = @root.episode.to_a
    @latest = @incidents.last
    @label = AgentMessages::FloorAlert.label(@root)
    @opens = @incidents.size
    @since = AgentMessages::FloorAlert.clock(@root.opened_at)
    @open_minutes = ((Time.current - @latest.opened_at) / 60).floor
    @lasted = (((@latest.resolved_at || Time.current) - @root.opened_at) / 60).floor
    @alert = AgentMessages::FloorAlert.alert_text(@latest)
    @sop_path = SOP_PATH
    @sop_url = SOP_URL
  end
end
