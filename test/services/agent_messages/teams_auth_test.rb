require "test_helper"
require_relative "../../support/teams_fixtures"

# [unit] The Bot Framework JWT check on POST /webhooks/teams/messages
# (AgentMessages::TeamsAuth), against a local JWKS: a good token passes, and a
# bad signature, the wrong issuer, the wrong audience, an expired token, a
# serviceUrl mismatch, a missing endorsement, a missing Bearer and alg none are
# each refused; an unknown kid refetches the keys once, and only once per gap.
class AgentMessagesTeamsAuthTest < ActiveSupport::TestCase
  include TeamsFixtures

  setup do
    @cache = AgentMessages::TeamsAuth::KeyCache.new
    @fetcher = teams_fetcher
  end

  def auth(fetcher: @fetcher, now: -> { Time.current })
    AgentMessages::TeamsAuth.new(app_id: APP_ID, fetcher: fetcher, cache: @cache, now: now)
  end

  def activity = teams_activity

  def verify(token, act = activity, **kw) = auth(**kw).verify("Bearer #{token}", act)

  test "[unit] a token signed by the Bot Framework key, for our app id and this serviceUrl, passes" do
    result = verify(teams_token)

    assert result.ok?, result.reason
    assert_equal APP_ID, result.claims["aud"]
    assert_equal 2, @fetcher.urls.size, "the metadata, then the JWKS"
    verify(teams_token)
    assert_equal 2, @fetcher.urls.size, "the keys are cached"
  end

  test "[unit] a bad signature is refused (signed by a key whose kid is the real one)" do
    result = verify(teams_token(key: TeamsFixtures.other_key))

    refute result.ok?
    assert_equal 401, result.status
    assert_match "signature", result.reason
  end

  test "[unit] the wrong issuer is refused" do
    result = verify(teams_token(iss: "https://sts.windows.net/someone-else/"))

    refute result.ok?
    assert_match "issuer", result.reason
  end

  test "[unit] the wrong audience is refused" do
    result = verify(teams_token(aud: "another-bot"))

    refute result.ok?
    assert_match "audience", result.reason
  end

  test "[unit] an expired token is refused past the five-minute skew, and passes inside it" do
    refute verify(teams_token(exp: 6.minutes.ago)).ok?
    assert_match "expired", verify(teams_token(exp: 6.minutes.ago)).reason
    assert verify(teams_token(exp: 2.minutes.ago)).ok?, "inside Microsoft's 5-minute skew"
  end

  test "[unit] a serviceUrl claim that does not match the activity's is refused" do
    result = verify(teams_token(service_url: "https://evil.example/"))

    refute result.ok?
    assert_match "serviceUrl", result.reason
    refute verify(teams_token(service_url: nil)).ok?, "a token with no serviceUrl claim"
  end

  test "[unit] a key not endorsed for msteams answers 403" do
    @fetcher.keys = [ teams_jwk(endorsements: [ "webchat" ]) ]
    result = verify(teams_token)

    refute result.ok?
    assert_equal 403, result.status
    assert_match "endorsed", result.reason
  end

  test "[unit] an unknown kid refetches the keys once, then is found; a second unknown kid inside the gap does not refetch" do
    verify(teams_token) # warm the cache with KID
    @fetcher.keys = [ teams_jwk, teams_jwk(TeamsFixtures.other_key, kid: "rotated-in") ]

    result = verify(teams_token(key: TeamsFixtures.other_key, kid: "rotated-in"))
    assert result.ok?, result.reason
    assert_equal 4, @fetcher.urls.size, "one refetch: metadata + JWKS again"

    refused = verify(teams_token(kid: "made-up"))
    refute refused.ok?
    assert_match "unknown signing key", refused.reason
    assert_equal 4, @fetcher.urls.size, "no second refetch inside REFETCH_GAP"
  end

  test "[unit] no Bearer, a non-JWT, alg none and an unset app id are refused, and no reason carries the token" do
    token = teams_token
    assert_equal 401, auth.verify(nil, activity).status
    assert_equal 401, auth.verify("Basic abc", activity).status
    refute auth.verify("Bearer not.a.jwt", activity).ok?
    none = JWT.encode({ iss: AgentMessages::TeamsAuth::ISSUER, aud: APP_ID, serviceUrl: SERVICE_URL }, nil, "none")
    assert_match "alg", auth.verify("Bearer #{none}", activity).reason
    unset = AgentMessages::TeamsAuth.new(app_id: "", fetcher: @fetcher, cache: @cache).verify("Bearer #{token}", activity)
    refute unset.ok?

    [ verify(teams_token(aud: "x")), verify(teams_token(key: TeamsFixtures.other_key)) ].each do |r|
      refute_includes r.reason, token
      refute_includes r.reason, token.split(".").last
    end
  end

  test "[unit] keys that cannot be fetched refuse the request rather than raise" do
    down = ->(_url) { raise AgentMessages::TeamsAuth::KeysUnavailable, "HTTP 503 from login.botframework.com" }
    result = verify(teams_token, fetcher: down)

    refute result.ok?
    assert_match "could not be fetched", result.reason
  end

  test "[unit] a due refresh that fails keeps the keys already held" do
    verify(teams_token)
    later = -> { 13.hours.from_now }
    down = ->(_url) { raise AgentMessages::TeamsAuth::KeysUnavailable, "down" }

    assert verify(teams_token(exp: 14.hours.from_now), fetcher: down, now: later).ok?
  end
end
