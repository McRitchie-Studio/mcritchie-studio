# The agent shell's size step (agent_chats/_shell, task build-launch-chat-growth):
# how far the head and status card have compacted for a thread of `turns` turns.
# app/javascript/agent_shell.js reads the same thresholds off the shell's data
# attributes, so the server's first paint and the page's later steps agree.
module AgentShellHelper
  # The first answer starts the conversation: the heading and portrait shrink.
  MEDIUM_AT = 1
  # By the third turn the thread is the page: the head is one line.
  COMPACT_AT = 3

  def agent_shell_size(turns)
    turns = turns.to_i
    if turns >= COMPACT_AT then "compact"
    elsif turns >= MEDIUM_AT then "medium"
    else "full"
    end
  end
end
