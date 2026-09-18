require "net/http"
require "json"
require "base64"

module Gmail
  # Thin Net::HTTP wrapper over the four Gmail Web API methods the ingest needs.
  #
  # READ-ONLY BY CONSTRUCTION, and that is the load-bearing property of this
  # file. There is no method here that sends, replies, labels, archives, drafts
  # or deletes, and there is no way to add one by accident: every Gmail call
  # goes through #get, which builds a Net::HTTP::Get and nothing else. A leaked
  # credential from this lane cannot speak in the mailbox, and it cannot change
  # what is in it.
  #
  # The ONE POST in this file is the OAuth token refresh, and it is addressed to
  # Google's token endpoint (TOKEN_URI), never to the Gmail API. That asymmetry
  # is deliberate and tested: the suite asserts every Gmail-facing method issues
  # a GET.
  class Client
    BASE      = "https://gmail.googleapis.com/gmail/v1".freeze
    TOKEN_URI = "https://oauth2.googleapis.com/token".freeze

    # The whole grant. One entry, frozen, and asserted by the suite — widening
    # this list is the only way this lane could ever gain a write, so it is
    # written where a reviewer cannot miss it.
    #
    # NOT gmail.modify (which also permits send), NOT gmail.compose (which
    # covers drafts AND send — there is no draft-only Gmail scope). Archiving or
    # labelling a message we have read would need one of those, which is why
    # this ingest deliberately leaves the mailbox untouched and tracks its
    # position in our own database instead.
    SCOPES = [ "https://www.googleapis.com/auth/gmail.readonly" ].freeze

    Error = Class.new(StandardError)

    # Google answered, and said no. Carries the API's own reason slug so
    # callers can tell rateLimitExceeded from notFound.
    class ApiError < Error
      attr_reader :status, :reason, :retry_after

      def initialize(status, reason, method, retry_after: nil)
        @status = status
        @reason = reason
        @retry_after = retry_after
        super("Gmail #{method} failed: HTTP #{status}#{" (#{reason})" if reason}")
      end
    end

    # The cursor is older than Gmail's history retention. Recoverable — the
    # caller falls back to a bounded full sync — so it is its own type rather
    # than a generic 404.
    CursorExpired = Class.new(Error)

    # The refresh token no longer works. THE most likely cause is a password
    # change on the mailbox account: Google invalidates refresh tokens carrying
    # Gmail scopes when the user changes their password. Also fires after six
    # months unused, or an explicit revoke. This must never be mistaken for a
    # quiet mailbox, so it is loud and it names its own remedy.
    class CredentialRevoked < Error
      def initialize(detail = nil)
        super("Gmail refresh token rejected#{" (#{detail})" if detail}. A password change on " \
              "the mailbox account invalidates Gmail-scoped refresh tokens — re-mint with " \
              "bin/gmail-oauth-mint and re-file gmail.studio.agents.")
      end
    end

    # Transport failures surface as many concrete classes; every one arrives
    # wrapped so callers rescue ONE type.
    TRANSPORT_ERRORS = [
      SocketError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError, IOError, SystemCallError
    ].freeze

    # Gmail answers 429, and also 403 with a rateLimitExceeded reason. Both
    # retry; a plain 403 (insufficient scope) does not, because retrying a
    # permission refusal is just a slower refusal.
    MAX_RETRIES = 5
    RETRYABLE_REASONS = %w[rateLimitExceeded userRateLimitExceeded backendError internalError].freeze

    def initialize(credentials: Credentials, sleeper: ->(seconds) { sleep(seconds) })
      @credentials = credentials
      @sleeper = sleeper
    end

    # Proves the credential and names the mailbox it opened. Called first by the
    # ingest so a misfiled credential fails before any message is fetched, and
    # so the operator output can never be ambiguous about WHICH mailbox answered.
    def profile
      get("users/me/profile")
    end

    # One page of message ids matching `query`. The query goes in the REQUEST,
    # not in a filter over the results: a non-matching message is never
    # downloaded, so its body never enters this process. A bug in the query
    # fetches too little, which is an error; a bug in a post-filter would leak,
    # which is not.
    def messages_list(query:, cursor: nil, limit: 100)
      raise Error, "refusing to list messages without a query" if query.to_s.strip.empty?

      get("users/me/messages", q: query, pageToken: cursor, maxResults: limit)
    end

    # One message, with `format=raw` so the body carries the full RFC822 source.
    # That is what makes the desk bucket's .eml the same shape as the Resend
    # leg's, so the existing DeskCapture::Parser handles both with no special
    # case.
    #
    # Returns the whole Message resource rather than just the bytes, because it
    # also carries `historyId` — and taking both from ONE request is the
    # difference between one call per message and two.
    def message(id)
      get("users/me/messages/#{id}", format: "raw")
    end

    # Gmail encodes `raw` as base64url, sometimes unpadded; Ruby's
    # urlsafe_decode64 pads for us.
    def self.decode_raw(body, id: nil)
      encoded = body["raw"] or raise Error, "Gmail message #{id || body['id']} carried no raw payload"

      Base64.urlsafe_decode64(encoded)
    end

    # Changes since `start_history_id`. A 404 here means the cursor has aged out
    # of Gmail's history window — recoverable, and distinct from every other
    # failure, so it gets its own exception for the caller to fall back on.
    def history_list(start_history_id:, cursor: nil, limit: 100)
      get("users/me/history", startHistoryId: start_history_id, pageToken: cursor,
                              maxResults: limit, historyTypes: "messageAdded")
    rescue ApiError => e
      raise CursorExpired, "history cursor #{start_history_id} is no longer valid" if e.status == 404

      raise
    end

    # Walks every page of a paged method and concatenates the values under
    # `key`. Google signals "no more pages" by OMITTING nextPageToken; an empty
    # string would loop forever, so .presence guards both shapes.
    def paged(method, key, **params)
      out = []
      cursor = nil
      loop do
        body = public_send(method, cursor: cursor, **params)
        out.concat(Array(body[key]))
        cursor = body["nextPageToken"].presence
        break if cursor.nil?
      end
      out
    end

    # Exchanged lazily and cached for the life of the instance. Short-lived by
    # design (Google issues ~1h), so nothing here is worth persisting.
    def access_token
      @access_token ||= refresh_access_token
    end

    private

    # EVERY Gmail-facing call funnels through here, and it can only ever GET.
    def get(path, **params)
      uri = URI("#{BASE}/#{path}")
      uri.query = URI.encode_www_form(params.compact) if params.compact.any?

      with_retries(path) do
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{access_token}"
        parse_response(perform(uri, request), path)
      end
    end

    def with_retries(path)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue ApiError => e
        raise e unless retryable?(e)
        raise Error, "Gmail #{path} rate-limited #{attempts} times; giving up" if attempts > MAX_RETRIES

        @sleeper.call(backoff(attempts, e))
        retry
      end
    end

    def retryable?(error)
      error.status == 429 ||
        (error.status == 403 && RETRYABLE_REASONS.include?(error.reason)) ||
        (error.status >= 500 && error.status < 600)
    end

    def backoff(attempts, error)
      error.retry_after || (2**(attempts - 1))
    end

    def refresh_access_token
      raise Error, "no Gmail credential configured" unless @credentials.configured?

      credential = @credentials.credential
      uri = URI(TOKEN_URI)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(
        client_id: credential["client_id"],
        client_secret: credential["client_secret"],
        refresh_token: credential["refresh_token"],
        grant_type: "refresh_token"
      )

      response = perform(uri, request)
      body = JSON.parse(response.body.to_s.presence || "{}") rescue {}

      # invalid_grant is the revoked/expired signal and arrives as a 400.
      raise CredentialRevoked, body["error"] if body["error"] == "invalid_grant"
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Gmail token refresh returned HTTP #{response.code}: #{body['error'] || 'unknown'}"
      end

      body["access_token"].presence or raise Error, "Gmail token refresh returned no access_token"
    end

    def parse_response(response, path)
      if response.is_a?(Net::HTTPSuccess)
        return JSON.parse(response.body.to_s.presence || "{}")
      end

      body = begin
        JSON.parse(response.body.to_s.presence || "{}")
      rescue JSON::ParserError
        {}
      end
      reason = body.dig("error", "errors", 0, "reason") || body.dig("error", "status")
      raise CredentialRevoked, "token rejected by #{path}" if response.code.to_i == 401

      raise ApiError.new(response.code.to_i, reason, path,
                         retry_after: response["Retry-After"]&.to_i)
    rescue JSON::ParserError => e
      raise Error, "Gmail #{path} returned unparseable JSON: #{e.message}"
    end

    def perform(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end
    rescue *TRANSPORT_ERRORS => e
      raise Error, "#{e.class}: #{e.message}"
    end
  end
end
