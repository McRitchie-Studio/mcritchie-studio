# The agent shell's size step (agent_chats/_shell; tasks build-launch-chat-growth,
# build-chat-reading-flow). The head compacts as the THREAD GROWS, not as messages
# are sent: app/javascript/agent_shell.js reads the thread's height against the
# shell's room (the window below where the shell starts) and steps forward past
# these shares of it, or whenever the thread has to scroll at the step it is on.
# The server cannot measure a height, so `agent_shell_size` is only the first
# paint's guess from the turn count; the page measures afresh on load.
module AgentShellHelper
  # Past this share of the room the conversation has started: the heading and
  # portrait shrink and /build's gallery slides away.
  MEDIUM_SHARE = 0.3
  # Past this share the thread is the page: the head is one line.
  COMPACT_SHARE = 0.55

  # The first paint's guess (a turn is the visitor's words and the answer): one
  # turn usually still fits beside the full head, three rarely do.
  MEDIUM_AT = 2
  COMPACT_AT = 3

  # Ritch's Agent row, for the portrait in a pending /build turn's thinking look
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
