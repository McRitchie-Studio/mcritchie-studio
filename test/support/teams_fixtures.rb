require "jwt"
require "openssl"

# Microsoft Teams test builders (docs/agents/system/agent-message-loop.md,
# "Teams"): a local Bot Framework signing key and JWKS served by a fake
# fetcher (no request leaves the process), tokens signed with it, and Bot
# Framework activities in the shapes learn.microsoft.com documents.
module TeamsFixtures
  APP_ID = "00000000-0000-4000-8000-00000000b07a".freeze
  TENANT = "11111111-1111-4111-8111-111111111111".freeze
  OWNER_AAD = "22222222-2222-4222-8222-222222222222".freeze
  SERVICE_URL = "https://smba.trafficmanager.net/amer/".freeze
  CHANNEL = "19:general0000000000000000000000@thread.tacv2".freeze
  TEAM = "19:team000000000000000000000000000@thread.tacv2".freeze
  KID = "test-kid-1".freeze

  # One RSA key per process: generating 2048-bit keys per test is slow.
  def self.signing_key = @signing_key ||= OpenSSL::PKey::RSA.generate(2048)
  def self.other_key = @other_key ||= OpenSSL::PKey::RSA.generate(2048)

  # Answers the OpenID metadata and the JWKS for the local key; counts fetches.
  class FakeFetcher
    attr_reader :urls
    attr_accessor :keys

    def initialize(keys)
      @keys = keys
      @urls = []
    end

    def call(url)
      @urls << url
      if url == AgentMessages::TeamsAuth::OPENID_URL
        { issuer: AgentMessages::TeamsAuth::ISSUER, jwks_uri: "https://login.botframework.com/v1/.well-known/keys",
          id_token_signing_alg_values_supported: [ "RS256" ] }.to_json
      else
        { keys: @keys }.to_json
      end
    end
  end

  def teams_jwk(key = TeamsFixtures.signing_key, kid: KID, endorsements: [ "msteams" ])
    JWT::JWK.new(key.public_key, kid: kid).export.transform_keys(&:to_s).merge("endorsements" => endorsements)
  end

  def teams_fetcher(keys = [ teams_jwk ]) = FakeFetcher.new(keys)

  def teams_token(key: TeamsFixtures.signing_key, kid: KID, iss: AgentMessages::TeamsAuth::ISSUER, aud: APP_ID,
                  exp: 1.hour.from_now, service_url: SERVICE_URL, alg: "RS256", **claims)
    payload = { iss: iss, aud: aud, exp: exp.to_i, nbf: 5.minutes.ago.to_i, serviceUrl: service_url }.merge(claims).compact
    JWT.encode(payload, key, alg, { kid: kid }.compact)
  end

  # A Teams channel message activity (channel-and-group-conversations): the
  # thread root's id in conversation.id after ;messageid=.
  def teams_activity(text: "Avi, what shipped?", id: "1761900000001", root: nil, from_aad: "33333333-0000-4000-8000-000000000001",
                     from_name: "Pat Member", channel: CHANNEL, mention_bot: false, conversation_type: "channel", **extra)
    root ||= id
    entities = []
    if mention_bot
      text = "<at>McRitchie Agents</at> #{text}"
      entities << { "type" => "mention", "text" => "<at>McRitchie Agents</at>",
                    "mentioned" => { "id" => "28:#{APP_ID}", "name" => "McRitchie Agents" } }
    end
    conversation_id = conversation_type == "channel" ? "#{channel};messageid=#{root}" : channel
    {
      "type" => "message", "id" => id, "timestamp" => "2026-10-30T22:00:00.000Z", "channelId" => "msteams",
      "serviceUrl" => SERVICE_URL, "text" => text, "textFormat" => "plain",
      "from" => { "id" => "29:user-#{from_aad[0, 8]}", "name" => from_name, "aadObjectId" => from_aad },
      "conversation" => { "id" => conversation_id, "conversationType" => conversation_type, "isGroup" => conversation_type != "personal",
                          "tenantId" => TENANT },
      "recipient" => { "id" => "28:#{APP_ID}", "name" => "McRitchie Agents" },
      "entities" => entities,
      "channelData" => { "tenant" => { "id" => TENANT }, "team" => { "id" => TEAM, "name" => "McRitchie Studio" },
                         "channel" => ({ "id" => channel, "name" => "General" } if conversation_type == "channel") }.compact
    }.merge(extra.transform_keys(&:to_s))
  end

  # The conversationUpdate a team install sends (subscribe-to-conversation-events).
  def teams_install_activity(channel: CHANNEL)
    {
      "type" => "conversationUpdate", "id" => "f:install-1", "channelId" => "msteams", "serviceUrl" => SERVICE_URL,
      "membersAdded" => [ { "id" => "28:#{APP_ID}" } ],
      "from" => { "id" => "29:installer", "aadObjectId" => OWNER_AAD },
      "conversation" => { "isGroup" => true, "conversationType" => "channel", "tenantId" => TENANT, "id" => channel,
                          "name" => "General" },
      "recipient" => { "id" => "28:#{APP_ID}", "name" => "McRitchie Agents" },
      "channelData" => { "settings" => { "selectedChannel" => { "id" => channel } },
                         "team" => { "aadGroupId" => "g1", "name" => "McRitchie Studio", "id" => TEAM },
                         "eventType" => "teamMemberAdded", "tenant" => { "id" => TENANT } }
    }
  end

  def teams_routes(channels: {}, owner: OWNER_AAD, **overrides)
    AgentMessages::TeamsRoutes.new({
      "tenant_id" => TENANT, "bot_app_id" => APP_ID, "owner_aad_object_id" => owner, "mention_soul" => "alex",
      "souls" => { "avi" => { "names" => [ "Avi" ] }, "alex" => { "names" => [ "Alex" ] },
                   "mason" => { "names" => [ "Mason" ] }, "turf_monster" => { "names" => [ "Turf" ] } },
      "recognized" => { "hank" => { "names" => [ "Hank" ] } },
      "core_souls" => %w[alex mason avi],
      "channels" => channels
    }.merge(overrides.transform_keys(&:to_s)))
  end
end
