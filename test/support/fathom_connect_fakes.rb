# Stand-ins for Fathom's token and read endpoints, for tests of the Fathom
# connection (FathomConnection, Fathom::*). No test here reaches Fathom.
module FathomConnectFakes
  CREDS = { "FATHOM_CLIENT_ID" => "test-fathom-id", "FATHOM_CLIENT_SECRET" => "test-fathom-secret" }.freeze

  def with_fathom_env(creds: true)
    originals = CREDS.keys.index_with { |k| ENV[k] }
    CREDS.each { |k, v| creds ? ENV[k] = v : ENV.delete(k) }
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def fathom_grant(refresh_token: "fathom-synthetic-refresh", access_token: "fathom-synthetic-access")
    { access_token:, refresh_token:, expires_in: 3600, token_type: "Bearer" }
  end

  def store_fathom(account: "alex@mcritchie.studio", refresh_token: "fathom-synthetic-refresh")
    FathomConnection.store!(fathom_grant(refresh_token:).transform_keys(&:to_s), account:, by: "alex")
  end

  # Answers every token POST with `answers` in turn ([status, body Hash] each;
  # the last repeats), and records each form.
  def fathom_tokens(*answers)
    fathom_token_requests.clear
    answers = [ [ 200, fathom_grant ] ] if answers.empty?
    Fathom::OAuthClient.http = lambda do |url, form|
      fathom_token_requests << { url:, form: }
      status, body = answers.size > 1 ? answers.shift : answers.first
      [ status, JSON.generate(body) ]
    end
  end

  def fathom_token_requests = (@fathom_token_requests ||= [])

  # Answers every read GET by the first matching path prefix under the API
  # ({ "/meetings" => [status, body Hash] }), and records each URL and token.
  def fathom_reads(routes)
    fathom_read_requests.clear
    Fathom::Reader.http = lambda do |url, token|
      fathom_read_requests << [ url, token ]
      path = url.delete_prefix(Fathom::Reader::API_URL)
      status, body = routes.find { |prefix, _| path.start_with?(prefix) }&.last || [ 404, { message: "unrouted" } ]
      [ status, JSON.generate(body) ]
    end
  end

  def fathom_read_requests = (@fathom_read_requests ||= [])

  MEETINGS = {
    items: [
      { meeting_title: "Older call", created_at: "2026-10-13T15:00:00Z", recording_id: 7, url: "https://fathom.video/calls/7" },
      { title: "Lender call", created_at: "2026-10-14T16:00:00Z", recording_id: 9, url: "https://fathom.video/calls/9",
        recorded_by: { name: "Alex", email: "Alex@McRitchie.studio" } }
    ],
    next_cursor: "cur-2"
  }.freeze
  TRANSCRIPT = { transcript: [
    { speaker: { display_name: "Alex" }, text: "Morning.", timestamp: "00:00:01" },
    { speaker: { display_name: "Lender" }, text: "Morning, Alex McRitchie.", timestamp: "00:00:03" },
    { speaker: { display_name: "Alex" }, text: "The term sheet.", timestamp: "00:00:07" }
  ] }.freeze
  SUMMARY = { summary: { markdown_formatted: "## Lender call\n\n- Term sheet agreed." } }.freeze

  # Every read the admin page makes, answered.
  def fathom_reads_answer_everything
    fathom_reads("/meetings" => [ 200, MEETINGS ], "/recordings/9/transcript" => [ 200, TRANSCRIPT ], "/recordings/9/summary" => [ 200, SUMMARY ])
  end

  def reset_fathom_connect
    Fathom::OAuthClient.http = nil
    Fathom::OAuthClient.sign_in_stand_in = nil
    Fathom::Reader.http = nil
  end
end
