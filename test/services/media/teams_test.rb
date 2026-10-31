require "test_helper"
require_relative "../../support/agent_message_fixtures"
require_relative "../../support/teams_fixtures"

# [unit] Media::Teams with the Bot Connector stubbed: each reply is ONE
# Adaptive Card headed with the soul's name and portrait, sent to the inbound
# activity in its channel thread with an app-only token cached until expiry;
# the retry policy is Slack's (only a provable non-send is retried: a 429, a
# 412, a 401, a token failure; a 5xx or a timeout is ambiguous and never
# re-sent); a reply with no credentials is skipped; the noise caps count
# Teams' own ledger rows; posts need a stored conversation reference, open a
# thread or post in one, and a keyed post goes out once.
class MediaTeamsTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include TeamsFixtures

  TOKEN_URL = "https://login.microsoftonline.com/#{TENANT}/oauth2/v2.0/token".freeze

  # Answers the token endpoint and then each Connector call from `answers`
  # (an [status, headers, body], an exception, or nil for a 200 with an id).
  class FakeConnector
    attr_reader :calls, :token_calls

    def initialize(*answers, token: [ 200, {}, { token_type: "Bearer", expires_in: 3600, access_token: "tok-1" }.to_json ])
      @answers = answers
      @token = token
      @calls = []
      @token_calls = 0
      @seq = 0
    end

    def call(_method, url, headers, body)
      if url.include?("login.microsoftonline.com")
        @token_calls += 1
        @last_form = body
        raise @token if @token.is_a?(Exception) || (@token.is_a?(Class) && @token <= Exception)

        return @token
      end
      @calls << { url: url, headers: headers, body: JSON.parse(body) }
      answer = @answers.shift
      raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer <= Exception)
      return answer if answer

      @seq += 1
      [ 201, {}, { id: "1761900009#{format('%03d', @seq)}", activityId: "1761900009#{format('%03d', @seq)}" }.to_json ]
    end

    attr_reader :last_form
  end

  def client(transport, now: -> { Time.current }, cache: Media::Teams::Client::TokenCache.new)
    Media::Teams::Client.new(app_id: APP_ID, password: "secret-pw", tenant_id: TENANT, transport: transport,
                             token_cache: cache, now: now)
  end

  def adapter(transport, caps: nil, **kw)
    teams = Media::Teams.new(client: client(transport, **kw))
    teams.instance_variable_set(:@limits, caps || Media::Teams::Limits.new({}, owner_user_id: OWNER_AAD))
    teams
  end

  def teams_row(soul: "avi", text: "**Green.** QA passed.", id: "1761900000001", root: "1761900000001", author: "someone")
    agent_message!(soul: soul, status: "completed", channel: "teams", external_id: "#{CHANNEL}:#{id}", channel_ref: CHANNEL,
                   thread_key: "teams:#{CHANNEL}:#{root}", author_ref: author, response_text: text, reply_status: "queued",
                   envelope: { "service_url" => SERVICE_URL, "conversation_id" => "#{CHANNEL};messageid=#{root}",
                               "activity_id" => id, "thread_root" => root, "from_id" => "29:user-1", "conversation_type" => "channel" })
  end

  def home(id = CHANNEL) = Media::Home.new(medium: "teams", channel: "general", spec: { "id" => id }, source: "test", fell_from: [])

  def reference! = TeamsConversation.remember!(conversation_id: CHANNEL, service_url: SERVICE_URL, tenant_id: TENANT,
                                               team_id: TEAM)

  # --- the card ---------------------------------------------------------------

  test "[unit] the card: Adaptive Card 1.5, headed with the soul's name and an absolute portrait, the text wrapped and clipped" do
    who = Media::Teams.new(client: client(FakeConnector.new)).identity_for("avi")
    assert_equal "Avi", who[:name]
    assert_equal "https://mcritchie.studio/slack-icons/avi.png", who[:icon_url], "the portrait Slack uses"

    card = Media::Teams::Card.activity(text: "x" * 25_000, name: who[:name], icon_url: who[:icon_url])
    attachment = card[:attachments].sole
    assert_equal "application/vnd.microsoft.card.adaptive", attachment[:contentType]
    content = attachment[:content]
    assert_equal [ "AdaptiveCard", "1.5" ], content.values_at(:type, :version)
    header, body = content[:body]
    image, name = header[:columns]
    assert_equal [ "Image", "https://mcritchie.studio/slack-icons/avi.png", "Person" ], image[:items].sole.values_at(:type, :url, :style)
    assert_equal [ "Avi", "Bolder" ], name[:items].sole.values_at(:text, :weight)
    assert_equal Media::Teams::Card::TEXT_LIMIT, body[:text].length
    assert body[:wrap]
    assert_operator card.to_json.bytesize * 2, :<, 80_000, "under Teams' safe 80 KB counted as UTF-16"
  end

  test "[unit] a long post is chunked into several cards; embeds become a title, a FactSet and a footer" do
    long = ([ "a line of the release note" ] * 2_000).join("\n")
    cards = Media::Teams::Card.messages(content: long, name: "Mason",
                                        embeds: [ { title: "hub", url: "https://mcritchie.studio", description: "shipped",
                                                    fields: [ { name: "SHA", value: "abc123" } ], footer: { text: "rel-1" } } ])
    assert_operator cards.size, :>, 1
    last = cards.last[:attachments].sole[:content][:body]
    assert_equal "[hub](https://mcritchie.studio)", last.find { |b| b[:weight] == "Bolder" && b[:size] == "Medium" }[:text]
    assert_equal [ { title: "SHA", value: "abc123" } ], last.find { |b| b[:type] == "FactSet" }[:facts]
    assert_equal "rel-1", last.last[:text]
    assert_equal "ColumnSet", cards.first[:attachments].sole[:content][:body].first[:type], "the header leads the first card only"
    assert_equal "TextBlock", cards.second[:attachments].sole[:content][:body].first[:type]
  end

  # --- replies --------------------------------------------------------------------

  test "[unit] a reply is one card to the inbound activity, in its thread, with the app-only token; posted once" do
    connector = FakeConnector.new
    row = teams_row
    adapter(connector).deliver_reply(row)

    call = connector.calls.sole
    assert_equal "https://smba.trafficmanager.net/amer/v3/conversations/" \
                 "#{ERB::Util.url_encode("#{CHANNEL};messageid=1761900000001")}/activities/1761900000001", call[:url]
    assert_equal "Bearer tok-1", call[:headers]["Authorization"]
    body = call[:body]
    assert_equal [ "message", "1761900000001", "28:#{APP_ID}", "29:user-1" ],
                 [ body["type"], body["replyToId"], body.dig("from", "id"), body.dig("recipient", "id") ]
    assert_equal "#{CHANNEL};messageid=1761900000001", body.dig("conversation", "id")
    texts = body["attachments"].sole.dig("content", "body").flat_map { |b| b["columns"] ? b["columns"].flat_map { |c| c["items"] } : [ b ] }
    assert_includes texts.map { |b| b["text"] }, "Avi"
    assert_includes texts.map { |b| b["text"] }, "**Green.** QA passed."
    assert_includes connector.last_form, "scope=https%3A%2F%2Fapi.botframework.com%2F.default"
    assert_includes connector.last_form, "grant_type=client_credentials"
    refute_includes row.events.pluck(:detail).to_json, "secret-pw"

    row.reload
    assert_equal [ "posted", "1761900009001" ], [ row.reply_status, row.reply_external_id ]
    ledger = SlackPost.sole
    assert_equal [ "teams", CHANNEL, "1761900000001", "reply", "posted" ],
                 [ ledger.medium, ledger.channel_id, ledger.thread_ts, ledger.kind, ledger.status ]

    adapter(connector).deliver_reply(row)
    assert_equal 1, connector.calls.size, "never posted twice"
  end

  test "[unit] the token is cached until shortly before it expires, then minted again" do
    now = Time.current
    clock = -> { now }
    cache = Media::Teams::Client::TokenCache.new
    connector = FakeConnector.new
    c = client(connector, now: clock, cache: cache)

    2.times { c.send_to(SERVICE_URL, CHANNEL, { type: "message" }) }
    assert_equal 1, connector.token_calls
    now += 56.minutes
    c.send_to(SERVICE_URL, CHANNEL, { type: "message" })
    assert_equal 2, connector.token_calls, "inside the five-minute margin of a 3600 s token"
  end

  test "[unit] a 429 is NotPosted (raised for the job's retry, Retry-After kept); a 412 and a 401 are too, the 401 dropping the token" do
    row = teams_row
    error = assert_raises(Media::Teams::NotPosted) { adapter(FakeConnector.new([ 429, { "Retry-After" => "7" }, "{}" ])).deliver_reply(row) }
    assert_kind_of Media::Error, error
    assert_equal 7.0, error.retry_after
    assert_equal "reply_not_posted", row.events.order(:id).last.kind
    assert_equal "queued", row.reload.reply_status

    connector = FakeConnector.new([ 412, {}, "" ], [ 401, {}, "" ])
    teams = adapter(connector)
    assert_raises(Media::Teams::NotPosted) { teams.deliver_reply(row) }
    assert_raises(Media::Teams::NotPosted) { teams.deliver_reply(row) }
    teams.deliver_reply(row)
    assert_equal 2, connector.token_calls, "a 401 drops the cached token; the next try mints another"
    assert_equal "posted", row.reload.reply_status
  end

  test "[unit] a 5xx, a read timeout and an SSL error are ambiguous: failed, never re-sent" do
    [ [ 502, {}, "" ], [ 504, {}, "" ], Net::ReadTimeout, OpenSSL::SSL::SSLError ].each do |answer|
      row = teams_row(id: SecureRandom.hex(4))
      connector = FakeConnector.new(answer)
      adapter(connector).deliver_reply(row)
      adapter(connector).deliver_reply(row)

      assert_equal 1, connector.calls.size, "#{answer.inspect}: sent once, never again"
      assert_equal "failed", row.reload.reply_status
      assert_equal true, row.events.find_by(kind: "reply_failed").detail["ambiguous"]
    end
  end

  test "[unit] a refused reply (403, 404, 413, an untrusted serviceUrl, no reference) is failed and not retried" do
    [ [ 403, {}, { error: { code: "BotNotInConversationRoster" } }.to_json ], [ 413, {}, "" ] ].each do |answer|
      row = teams_row(id: SecureRandom.hex(4))
      adapter(FakeConnector.new(answer)).deliver_reply(row)
      assert_equal "failed", row.reload.reply_status
      assert_nil row.events.find_by(kind: "reply_failed").detail["ambiguous"]
    end

    evil = teams_row(id: "evil")
    evil.update!(envelope: evil.envelope.merge("service_url" => "https://attacker.example/"))
    connector = FakeConnector.new
    adapter(connector).deliver_reply(evil)
    assert_empty connector.calls, "our token never goes to a host that is not a Bot Connector"
    assert_includes evil.reload.events.find_by(kind: "reply_failed").detail["error"], "not a Bot Connector host"

    bare = teams_row(id: "bare")
    bare.update!(envelope: {})
    adapter(FakeConnector.new).deliver_reply(bare)
    assert_equal "failed", bare.reload.reply_status
  end

  test "[unit] a token the login service refuses is Refused; one it cannot give now is NotPosted; neither sends" do
    refused = FakeConnector.new(token: [ 401, {}, { error: "invalid_client" }.to_json ])
    row = teams_row(id: "t1")
    adapter(refused).deliver_reply(row)
    assert_equal "failed", row.reload.reply_status
    assert_empty refused.calls

    down = FakeConnector.new(token: Net::OpenTimeout)
    assert_raises(Media::Teams::NotPosted) { adapter(down).deliver_reply(teams_row(id: "t2")) }
    assert_empty down.calls
  end

  test "[unit] with no credentials a reply is skipped and recorded, and nothing is sent" do
    teams = Media::Teams.new(client: Media::Teams::Client.new(app_id: "", password: "", transport: ->(*) { flunk "sent" }))
    row = teams_row
    teams.deliver_reply(row)

    assert_equal "skipped", row.reload.reply_status
    assert_includes row.events.find_by(kind: "reply_skipped").detail["reason"], "TEAMS_BOT_APP_ID"
  end

  test "[unit] the thread root comes from the envelope, never from splitting the colon-filled thread key" do
    reply = teams_row(id: "1761900000222", root: "1761900000111")
    reply.update!(envelope: reply.envelope.merge("thread_root" => "1761900000111"))
    assert_equal "1761900000111", Media::Teams.thread_root(reply)

    root = teams_row(id: "1761900000333", root: "1761900000333")
    assert_equal "1761900000333", Media::Teams.thread_root(root), "a root post: its own activity id"

    odd = AgentMessage.new(channel: "teams", channel_ref: "a:1:chat", thread_key: "teams:a:1:chat:1:abc", envelope: {})
    assert_equal "1:abc", Media::Teams.thread_root(odd), "an id with a colon in it survives"
  end

  # --- the caps -------------------------------------------------------------------

  test "[unit] the caps count Teams' own rows: four agent posts in a thread suppress the next; Slack's rows never count" do
    4.times { SlackPost.create!(medium: "slack", channel_id: CHANNEL, thread_ts: "1761900000001", soul_slug: "avi", kind: "reply", status: "posted") }
    connector = FakeConnector.new
    adapter(connector).deliver_reply(teams_row(id: "c0"))
    assert_equal 1, connector.calls.size, "Slack's four do not count on Teams"

    3.times { SlackPost.create!(medium: "teams", channel_id: CHANNEL, thread_ts: "1761900000001", soul_slug: "mason", kind: "reply", status: "posted") }
    row = teams_row(id: "c1")
    adapter(connector).deliver_reply(row)

    assert_equal 1, connector.calls.size, "suppressed: nothing sent"
    assert_equal "skipped", row.reload.reply_status
    assert_match(/thread cap/, row.events.find_by(kind: "reply_suppressed").detail["reason"])
    assert_equal "suppressed", SlackPost.where(medium: "teams").order(:id).last.status
  end

  test "[unit] the owner's own message resets the thread cap on Teams (by Entra object id)" do
    4.times { SlackPost.create!(medium: "teams", channel_id: CHANNEL, thread_ts: "1761900000001", soul_slug: "mason", kind: "reply", status: "posted", created_at: 5.minutes.ago) }
    agent_message!(channel: "teams", external_id: "#{CHANNEL}:owner", channel_ref: CHANNEL, author_ref: OWNER_AAD,
                   thread_key: "teams:#{CHANNEL}:1761900000001", status: "completed")
    connector = FakeConnector.new
    adapter(connector).deliver_reply(teams_row(id: "c2", author: OWNER_AAD))

    assert_equal 1, connector.calls.size
  end

  # --- posts ----------------------------------------------------------------------

  test "[unit] a post opens a new thread in the channel through its stored reference, as the soul; more cards go in that thread" do
    reference!
    connector = FakeConnector.new
    long = ([ "line" ] * 6_000).join("\n")
    posted = adapter(connector).post(home, content: long, soul: "mason")

    first, second = connector.calls
    assert_equal "#{SERVICE_URL.delete_suffix('/')}/v3/conversations", first[:url]
    assert_equal [ true, CHANNEL, TENANT ], [ first[:body]["isGroup"], first[:body].dig("channelData", "channel", "id"),
                                             first[:body].dig("channelData", "tenant", "id") ]
    assert_equal "message", first[:body].dig("activity", "type")
    assert_includes second[:url], ERB::Util.url_encode("#{CHANNEL};messageid=1761900009001")
    assert_equal "1761900009002", posted["ts"]
    assert_equal %w[teams teams], SlackPost.order(:id).pluck(:medium)
  end

  test "[unit] a post with thread_ts goes in that thread; a keyed post goes out once; no reference refuses it" do
    reference!
    connector = FakeConnector.new
    teams = adapter(connector)
    teams.post(home, text: "smoke: green", soul: "steffon", thread_ts: "1761900000555", kind: "release", key: "release:r1:x:smoke")
    again = teams.post(home, text: "smoke: green", soul: "steffon", thread_ts: "1761900000555", kind: "release", key: "release:r1:x:smoke")

    assert_equal 1, connector.calls.size
    assert again["already_posted"]
    assert_includes connector.calls.sole[:url], ERB::Util.url_encode("#{CHANNEL};messageid=1761900000555")

    error = assert_raises(Media::Teams::Refused) { teams.post(home("19:never@thread.tacv2"), text: "hi", soul: "avi") }
    assert_equal "no_reference", error.code
    assert_equal "failed", SlackPost.order(:id).last.status
  end

  test "[unit] the shipped config: Teams disabled, its caps the shared limits block" do
    shipped = Media::Config.load
    refute shipped.enabled?("teams")
    caps = Media::Teams::Limits.current(config: shipped)
    assert_equal [ 6, 4, "teams" ], [ caps.per_hour, caps.per_thread, caps.medium ]
  end
end
