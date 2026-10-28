# The hub side of the agent chat every satellite app shares (epic
# .agents/epics/agent-chat-primitive.md; docs/agents/system/agent-message-loop.md,
# "Satellite chat"). A satellite's server posts what its visitor typed to
# POST /api/v1/agent_chat/messages (Api::V1::AgentChatsController) and polls
# GET /api/v1/agent_chat/turns; the hub stores each message as a `web`
# AgentMessage and the same bin/dispatcher loop answers it.
#
# ONE THREAD PER (PERSON, SOUL), the same on every app:
#
#   chat:<soul>:<hub user id>          a signed-in visitor whose email is a hub User
#   chat:<soul>:person:<person id>     a signed-in email with no hub User (its own AgentPerson)
#   chat:<soul>:anon:<token digest>    a signed-out visitor, by the app's anon cookie token
#
# The app a message came from is recorded on the row (envelope.app), never in the
# key, so a talk with Alex on alex.build is the same conversation on the hub.
module AgentChat
  THREAD_PREFIX = "chat:".freeze
  # Every row's channel_ref: one thread spans apps, so the ref names the API,
  # not an app (the CTO chat's is the app slug; /build's is "build").
  CHANNEL_REF = "chat".freeze
  SOUL = /\A[a-z][a-z0-9_]{1,40}\z/
  ANON_TOKEN = /\A[A-Za-z0-9_-]{16,128}\z/
  ANON_DIGEST_LENGTH = 32

  module_function

  def thread?(thread_key) = thread_key.to_s.start_with?(THREAD_PREFIX)

  # The thread prefix of one soul's chats ("chat:alex:"): Answerers answers the
  # public intake soul on these, as on /build.
  def soul_prefix(soul) = "#{THREAD_PREFIX}#{soul}:"

  def user_thread_key(soul, user_id) = "#{soul_prefix(soul)}#{Integer(user_id)}"
  def person_thread_key(soul, person_id) = "#{soul_prefix(soul)}person:#{Integer(person_id)}"
  def anon_thread_key(soul, digest) = "#{soul_prefix(soul)}anon:#{digest}"

  # The anon cookie token, keyed and cut: the thread key and the identity carry
  # this, never the token, so a leaked row cannot be replayed as the visitor.
  def anon_digest(token)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "agent-chat-anon:#{token}")[0, ANON_DIGEST_LENGTH]
  end

  # Whether satellite `app` may chat with `soul` (config/agent_routes.yml `web:`).
  def available?(app, soul, routes: AgentMessages::Routes.current)
    soul.to_s.match?(SOUL) && routes.web_app_soul?(app, soul)
  end

  # A thread's newest rows, oldest first; with `after`, the rows after that id.
  def rows(thread_key, after: nil, limit: AgentChat::Turns::LIMIT)
    scope = AgentMessage.where(channel: "web", thread_key: thread_key)
    return scope.where("id > ?", after).order(:id).limit(limit).to_a if after

    scope.order(id: :desc).limit(limit).to_a.reverse
  end
end
