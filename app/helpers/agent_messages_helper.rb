# Small readers for the /admin/agent_messages pages.
module AgentMessagesHelper
  # "4m", "2h", "3d": how long ago, at a glance.
  def agent_message_age(time, now: Time.current)
    return "—" if time.nil?

    seconds = (now - time).to_i
    return "#{[ seconds, 0 ].max}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600
    return "#{seconds / 3600}h" if seconds < 86_400

    "#{seconds / 86_400}d"
  end

  # The claim, as an operator reads it: who holds it and how long it has left.
  def agent_message_lease(message, now: Time.current)
    return nil unless message.claimed? && message.lease_expires_at

    left = (message.lease_expires_at - now).to_i
    left.positive? ? "lease #{left / 60}m #{left % 60}s left" : "lease lapsed #{agent_message_age(message.lease_expires_at, now: now)} ago"
  end

  def agent_message_filter_path(**overrides)
    current = { soul: @soul, status: @status, channel: @channel }
    admin_agent_messages_path(current.merge(overrides).compact)
  end
end
