# Stand-ins for Egnyte's token, revoke and Public API endpoints, for tests of
# the Egnyte connection (EgnyteConnection, Egnyte::*). No test here reaches Egnyte.
module EgnyteConnectFakes
  CREDS = { "EGNYTE_CLIENT_ID" => "test-egnyte-id", "EGNYTE_CLIENT_SECRET" => "test-egnyte-secret" }.freeze
  DOMAIN = "example".freeze

  def with_egnyte_env(creds: true)
    originals = CREDS.keys.index_with { |k| ENV[k] }
    CREDS.each { |k, v| creds ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def egnyte_grant(access_token: "egnyte-synthetic-access", refresh_token: "egnyte-synthetic-refresh", expires_in: 2_592_000)
    { access_token:, refresh_token:, expires_in:, token_type: "bearer" }
  end

  def store_egnyte(domain: DOMAIN, username: "alex", now: Time.current, **grant)
    EgnyteConnection.store!(egnyte_grant(**grant).transform_keys(&:to_s), domain:, username:, by: "alex", now:)
  end

  # Answers every token or revoke POST with `answers` in turn ([status, body]
  # each, a Hash body as JSON; the last repeats), and records each URL and form.
  def egnyte_tokens(*answers)
    egnyte_token_requests.clear
    answers = [ [ 200, egnyte_grant ] ] if answers.empty?
    Egnyte::OAuthClient.http = lambda do |url, form|
      egnyte_token_requests << { url:, form: }
      status, body = answers.size > 1 ? answers.shift : answers.first
      [ status, body.is_a?(String) ? body : JSON.generate(body) ]
    end
  end

  def egnyte_token_requests = (@egnyte_token_requests ||= [])

  # Answers every API call by the first route whose [method, path prefix]
  # matches (path after /pubapi/v1, query included), e.g.
  # { [:get, "/fs/Shared"] => [200, body] }. A route's answer may be a list of
  # answers given in turn (the last repeats). Records every call.
  def egnyte_reads(routes)
    egnyte_read_requests.clear
    routes = routes.transform_values { |answer| answer.first.is_a?(Array) ? answer.dup : [ answer ] }
    Egnyte::Reader.http = lambda do |method:, url:, token:, body:, headers:|
      egnyte_read_requests << { method:, url:, token:, body:, headers: }
      path = url.sub(%r{\Ahttps://[^/]+#{Regexp.escape(Egnyte::Reader::API_PATH)}}, "")
      queue = routes.find { |(verb, prefix), _| verb == method && path.start_with?(prefix) }&.last
      status, json = queue ? (queue.size > 1 ? queue.shift : queue.first) : [ 404, { errorMessage: "unrouted" } ]
      [ status, JSON.generate(json) ]
    end
  end

  def egnyte_read_requests = (@egnyte_read_requests ||= [])

  SHARED = {
    name: "Shared", path: "/Shared", folder_id: "f-root", is_folder: true, total_count: 3, offset: 0, count: 100,
    folders: [ { name: "Projects", path: "/Shared/Projects", folder_id: "f-1", is_folder: true, lastModified: 1_762_189_200_000 },
               { name: "Contracts", path: "/Shared/Contracts", folder_id: "f-2", is_folder: true } ],
    files: [ { name: "Read me.txt", path: "/Shared/Read me.txt", is_folder: false, size: 1023, entry_id: "e-1", group_id: "g-1",
               checksum: "abc", last_modified: "Tue, 03 Nov 2026 17:00:00 GMT", uploaded_by: "alex", num_versions: 3 } ]
  }.freeze
  WHOAMI = { username: "alex", domain: DOMAIN, scopes: "Egnyte.filesystem" }.freeze

  def reset_egnyte_connect
    Egnyte::OAuthClient.http = nil
    Egnyte::OAuthClient.sign_in_stand_in = nil
    Egnyte::Reader.http = nil
  end
end
