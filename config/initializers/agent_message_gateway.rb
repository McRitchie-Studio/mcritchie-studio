# The agent mailbox's Discord Gateway listener rides the Solid Queue SCHEDULER
# process of `bin/jobs` (the worker dyno): started when the scheduler boots,
# stopped before it shuts down. Only `bin/jobs` fires these hooks, and it runs a
# scheduler only where config/recurring.yml lists tasks (production), so web
# dynos, consoles, tests and desks never connect. Why the scheduler, the leader
# lock and the env switches: AgentMessages::DiscordGateway and
# docs/agents/system/agent-message-loop.md.
if defined?(SolidQueue)
  SolidQueue.on_scheduler_start { |_scheduler| AgentMessages::DiscordGateway.boot }
  SolidQueue.on_scheduler_stop { |_scheduler| AgentMessages::DiscordGateway.shutdown }
end
