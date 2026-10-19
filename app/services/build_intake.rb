# /build as a chat with Ray (.agents/epics/build-with-xan-design.md;
# docs/agents/system/agent-message-loop.md, "Build intake").
#
# A visitor tells Ray what they want to build. Ray asks, one at a time: the idea
# (at most two follow-ups), the colors (the theme), the CTO, the address. Each question
# arrives as a CARD inside the chat, and only the visitor's tap writes a field
# on their AppRequest.
#
#   thread    `web:build:<request token>`: the request's own conversation, so a
#             signed-out visitor has one before an account exists, and signing
#             in at Build only changes who the next message is from
#   cards     Ray's answer ends with a PROPOSAL block of kind "intake"
#             (AgentMailbox::ProposalBlock, the same delimiter as every other
#             proposal). BuildIntake::Card checks it in code; a card that fails is
#             an `intake_refused` event and is never shown
#   taps      BuildIntake::Choice writes cto_name, cto_avatar, palette, answers or
#             the subdomain, each re-validated on the server, and relays the
#             visitor's turn into the thread so Ray answers with the next step
#   who       Ray answers the public here and nowhere else, within BuildIntake::Caps
#             (AgentMessages::Answerers, config/agent_answerers.yml `public_intake`)
module BuildIntake
  THREAD_PREFIX = "web:build:".freeze
  # The channel_ref a build thread's rows carry (the CTO chat's is the app slug;
  # "build" is a reserved subdomain, so no app is ever named it).
  CHANNEL_REF = "build".freeze
  TOKEN = /\A[A-Za-z0-9_-]{16,64}\z/

  # The four things a request needs before Build my app lights up, in the
  # order Ray asks for them. The theme comes before the CTO: it is the easier
  # question (Alex, 2026-10-18). The order is only the asking order: a tap on
  # any card writes its field whatever is set already (BuildIntake::Choice), so
  # a draft that picked its CTO under the old order simply goes on to the theme.
  STEPS = %w[idea colors cto address].freeze

  module_function

  def thread_key(token) = "#{THREAD_PREFIX}#{token}"

  def thread?(thread_key) = thread_key.to_s.start_with?(THREAD_PREFIX)

  # The request token a build thread names, or nil.
  def token_from(thread_key)
    return nil unless thread?(thread_key)

    token = thread_key.to_s.delete_prefix(THREAD_PREFIX)
    token.match?(TOKEN) ? token : nil
  end

  def request_for(message)
    token = token_from(message.thread_key)
    token && AppRequest.find_by(token: token)
  end

  # The public-intake block of config/agent_answerers.yml
  # (AgentMessages::Answerers::PublicIntake), read once per process, or nil when
  # the file has none: then nobody signed out is answered on /build. Read apart
  # from Answerers.current so a test that swaps the answerers keeps the caps.
  def policy
    return @policy if defined?(@policy)

    @policy = AgentMessages::Answerers.load.public_intake
  end

  def policy=(value)
    @policy = value
  end

  def reset_policy!
    remove_instance_variable(:@policy) if defined?(@policy)
  end

  # The soul that runs intake: Ray unless the config names another.
  def soul = policy&.soul || "ray"

  def history(token, limit: AgentMessages::WebChat::HISTORY)
    AgentMessage.where(channel: "web", thread_key: thread_key(token)).order(id: :desc).limit(limit).to_a.reverse
  end
end
