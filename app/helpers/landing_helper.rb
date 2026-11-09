module LandingHelper
  MORPH_ATTR = ' data-vt-morph="agent-composer"'.freeze
  MORPH_STYLE = "view-transition-name: agent-composer;".freeze

  # The home page's chat with Alex (task get-in-touch-side-by-side): the
  # engine's compact chat, adjusted twice where the partial has no switch.
  #
  # A FRESH CHAT. Its polls carry `since`, the newest message id at render, so
  # it opens empty and shows only this visit's turns (HubAgentChatsController
  # #turns). Messages still land on the person's own thread, so /chat and the
  # agent's memory keep them. With old turns on the page the engine would
  # scroll the window to the newest one on load.
  #
  # NOT A MORPH PARTNER. The composer's agent-composer name would pair / with
  # /chat, and the engine would fade between them instead of sliding.
  def home_alex_chat
    since = AgentMessage.maximum(:id).to_i
    html = render("studio/agent_chat/chat", soul: "alex", name: "Alex", compact: true,
                  empty: "What brought you here today?").to_str
    turns = studio_agent_chat_turns_path
    html.sub(MORPH_ATTR, "").sub(MORPH_STYLE, "")
        .sub(%(data-agent-chat-turns-url="#{turns}"), %(data-agent-chat-turns-url="#{turns}?since=#{since}"))
        .html_safe # rubocop:disable Rails/OutputSafety -- the engine partial's own escaped output, edited only by the literals above
  end
end
