# Stand-ins for Microsoft's token and Graph endpoints, for tests of the
# Microsoft 365 connection (MsgraphConnection, Msgraph::*). No test here reaches
# Microsoft. Every tenant id is synthetic.
module MsgraphConnectFakes
  CREDS = { "MSGRAPH_CLIENT_ID" => "test-msgraph-id", "MSGRAPH_CLIENT_SECRET" => "test-msgraph-secret" }.freeze
  TENANT = "11111111-2222-4333-8444-555555555555".freeze
  OTHER_TENANT = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee".freeze

  def with_msgraph_env(creds: true)
    originals = CREDS.keys.index_with { |k| ENV[k] }
    CREDS.each { |k, v| creds ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def msgraph_grant(access_token: "graph-synthetic-access", expires_in: 3599)
    { token_type: "Bearer", expires_in:, access_token: }
  end

  def store_msgraph(tenant_id: TENANT, display_name: "Synthetic Org")
    MsgraphConnection.store!(tenant_id:, display_name:, by: "alex")
  end

  # Answers every token POST with `answers` in turn ([status, body Hash] each;
  # the last repeats), and records each URL and form.
  def msgraph_tokens(*answers)
    msgraph_token_requests.clear
    answers = [ [ 200, msgraph_grant ] ] if answers.empty?
    Msgraph::OAuthClient.http = lambda do |url, form|
      msgraph_token_requests << { url:, form: }
      status, body = answers.size > 1 ? answers.shift : answers.first
      [ status, JSON.generate(body) ]
    end
  end

  def msgraph_token_requests = (@msgraph_token_requests ||= [])

  # Answers every read GET by the first matching path prefix under the API
  # ({ "/users" => [status, body Hash] }), and records each URL and token.
  def msgraph_reads(routes)
    msgraph_read_requests.clear
    Msgraph::Reader.http = lambda do |url, token|
      msgraph_read_requests << [ url, token ]
      path = url.delete_prefix(Msgraph::Reader::API_URL)
      status, body = routes.find { |prefix, _| path.start_with?(prefix) }&.last || [ 404, { error: { code: "itemNotFound", message: "unrouted" } } ]
      [ status, JSON.generate(body) ]
    end
  end

  def msgraph_read_requests = (@msgraph_read_requests ||= [])

  ORGANIZATION = { id: TENANT, displayName: "Synthetic Org" }.freeze
  USERS = { value: [
    { id: "u1", displayName: "Ada", userPrincipalName: "ada@synthetic.example", mail: "ada@synthetic.example" },
    { id: "u2", displayName: "Bo", userPrincipalName: "bo@synthetic.example", mail: nil }
  ], "@odata.nextLink": "https://graph.microsoft.com/v1.0/users?$skiptoken=next" }.freeze
  TEAMS = { value: [ { id: "t1", displayName: "Shop", description: "The shop", visibility: "private" } ] }.freeze
  SITE = { id: "synthetic.sharepoint.example,1,2", displayName: "Home", webUrl: "https://synthetic.sharepoint.example" }.freeze
  DRIVES = { value: [ { id: "d1", name: "Documents", driveType: "documentLibrary", webUrl: "https://synthetic.sharepoint.example/d" } ] }.freeze

  # Every read the admin page makes, answered.
  def msgraph_reads_answer_everything
    msgraph_reads("/organization/" => [ 200, ORGANIZATION ], "/users" => [ 200, USERS ], "/teams" => [ 200, TEAMS ],
                  "/sites/root" => [ 200, SITE ], "/sites/" => [ 200, DRIVES ])
  end

  def reset_msgraph_connect
    Msgraph::OAuthClient.http = nil
    Msgraph::OAuthClient.sign_in_stand_in = nil
    Msgraph::OAuthClient.forget!
    Msgraph::Reader.http = nil
  end
end
