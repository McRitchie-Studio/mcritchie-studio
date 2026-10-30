require "test_helper"

# [unit] Slack's v0 request signature (AgentMessages::SlackSignature): the
# public events endpoint's whole security story.
class AgentMessages::SlackSignatureTest < ActiveSupport::TestCase
  SECRET = "8f742231b10e8888abcd99yyyzzz85a5".freeze
  BODY = '{"type":"event_callback","event":{"type":"message"}}'.freeze

  def sign(timestamp, body: BODY, secret: SECRET)
    "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{body}")}"
  end

  test "[unit] a good signature over v0:ts:raw_body verifies" do
    now = Time.current
    ts = now.to_i.to_s
    assert AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: ts, body: BODY, signature: sign(ts), now: now)
  end

  test "[unit] a bad signature, a changed body, another secret or a blank secret is refused" do
    ts = Time.current.to_i.to_s
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: ts, body: BODY, signature: "v0=#{'0' * 64}")
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: ts, body: "#{BODY} ", signature: sign(ts))
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: ts, body: BODY, signature: sign(ts, secret: "other"))
    refute AgentMessages::SlackSignature.valid?(secret: "", timestamp: ts, body: BODY, signature: sign(ts, secret: ""))
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: ts, body: BODY, signature: nil)
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: "abc", body: BODY, signature: sign("abc"))
  end

  test "[unit] a request more than five minutes old, or from the future, is refused even when signed" do
    now = Time.current
    stale = (now - 5.minutes - 1).to_i.to_s
    future = (now + 5.minutes + 1).to_i.to_s
    edge = (now - 5.minutes + 1).to_i.to_s
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: stale, body: BODY, signature: sign(stale), now: now)
    refute AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: future, body: BODY, signature: sign(future), now: now)
    assert AgentMessages::SlackSignature.valid?(secret: SECRET, timestamp: edge, body: BODY, signature: sign(edge), now: now)
  end
end
