# Stand-ins for TikTok's token endpoint, for tests of anything that reads the
# hub's TikTok grant. No test here reaches TikTok.
module TiktokOauthFakes
  CREDS = {
    "TIKTOK_CLIENT_KEY" => "test-client-key", "TIKTOK_CLIENT_SECRET" => "test-client-secret",
    "TIKTOK_REFRESH_TOKEN" => "test-refresh-token", "TIKTOK_OPEN_ID" => "test-open-id"
  }.freeze

  # Pins the four keys (or removes them, with `creds: false`) and any extras.
  def with_tiktok_env(creds: true, **extra)
    pins = CREDS.transform_values { |v| creds ? v : nil }.merge(extra.transform_keys(&:to_s))
    originals = pins.keys.index_with { |k| ENV[k] }
    pins.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # Answers every token request as TikTok would for a grant of `scope`, and
  # records each request's form params in `token_requests`.
  def tiktok_grants(scope, status: 200, body: nil)
    token_requests.clear
    Tiktok::OAuthClient.http = lambda do |params|
      token_requests << params
      [status, body || JSON.generate({ access_token: "act.test", refresh_token: "rft.test", open_id: "open-test",
                                       scope:, expires_in: 86_400, token_type: "Bearer" }.compact)]
    end
  end

  def token_requests = (@token_requests ||= [])

  def reset_tiktok_oauth
    Tiktok::OAuthClient.http = nil
  end
end
