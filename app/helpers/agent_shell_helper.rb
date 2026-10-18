# The agent shell's size step (agent_chats/_shell, task build-launch-chat-growth):
# how far the head and status card have compacted for a thread of `turns` turns.
# app/javascript/agent_shell.js reads the same thresholds off the shell's data
# attributes, so the server's first paint and the page's later steps agree.
module AgentShellHelper
  # The first answer starts the conversation: the heading and portrait shrink.
  MEDIUM_AT = 1
  # By the third turn the thread is the page: the head is one line.
  COMPACT_AT = 3

  # Ray's Agent row, for the portrait in a pending /build turn's thinking look
  # (build/_turn, agent_chats/_typing): read once per render, however many turns wait.
  def build_typing_agent
    return @build_typing_agent if defined?(@build_typing_agent)

    @build_typing_agent = Agent.find_by(slug: BuildIntake.soul)
  end

  def agent_shell_size(turns)
    turns = turns.to_i
    if turns >= COMPACT_AT then "compact"
    elsif turns >= MEDIUM_AT then "medium"
    else "full"
    end
  end
end
