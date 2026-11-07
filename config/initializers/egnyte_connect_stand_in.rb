# frozen_string_literal: true

# THE STAND-IN FOR EGNYTE when the Egnyte connection is walked without an
# Egnyte developer key: the e2e lane (it rides the lane's E2E_FAKE_VIDEO_STORAGE
# marker, as the Fathom, Google and TikTok stand-ins do) and a local demo
# (EGNYTE_STAND_IN=1, development only: a desk's .env also loads under the test
# environment, where the flag would hijack the unit tests). NEVER in production.
#
# Any domain the admin enters signs in: Egnyte's sign-in comes straight back to
# the callback with the stand-in's code. The token and revoke endpoints are
# stood in at the HTTP layer (Egnyte::OAuthClient.http), so the real exchange,
# refresh and rotation run: like Egnyte, a refresh answers a new refresh token,
# and the stand-in honours only the LAST one it issued for a domain. Its access
# tokens live an hour, inside EgnyteConnection::REFRESH_MARGIN, so every read
# refreshes: a refresh that failed to store its new pair would show up as
# Revoked on the next load.
#
# The memory is this process's own (the e2e server runs one). The reads answer
# a synthetic Shared root (two folders, one file), one subfolder, and an
# upload. The callback, the stored EgnyteConnection and the pages are real.
# The real request shapes are pinned by test/services/egnyte/.
module EgnyteConnectStandIn
  USERNAME = "stand.in"
  CODE = "egnyte-stand-in-code"

  class SignIn
    def authorize_url(domain:, redirect_uri:, state:) = "#{redirect_uri}?#{URI.encode_www_form(code: CODE, state:)}"
  end

  # Egnyte's token and revoke endpoints: (url, form) -> [status, body].
  class Tokens
    def initialize
      @live = {}
      @lock = Mutex.new
    end

    def call(url, form)
      host = URI(url).host
      @lock.synchronize do
        next [ 200, "" ] if url.end_with?(Egnyte::OAuthClient::REVOKE_PATH)

        case form[:grant_type]
        when "authorization_code"
          next [ 400, { error: "invalid_grant" }.to_json ] unless form[:code] == CODE

          issue(host)
        when "refresh_token"
          next [ 400, { message: "Invalid Refresh Token" }.to_json ] unless @live[host] && form[:refresh_token] == @live[host]

          issue(host)
        else [ 400, { error: "unsupported_grant_type" }.to_json ]
        end
      end
    end

    private

    def issue(host)
      @live[host] = "stand-in-refresh-#{SecureRandom.hex(8)}"
      [ 200, { access_token: "stand-in-access-#{SecureRandom.hex(8)}", refresh_token: @live[host], expires_in: 3600, token_type: "bearer" }.to_json ]
    end
  end

  MODIFIED = "Tue, 03 Nov 2026 17:00:00 GMT"

  READS = lambda do |method:, url:, token:, body:, headers:|
    path = URI(url).path.delete_prefix(Egnyte::Reader::API_PATH)
    answer =
      case [ method, path ]
      in [ :get, "/whoami" ] then { username: USERNAME, domain: URI(url).host.split(".").first }
      in [ :get, "/fs/Shared" ]
        { name: "Shared", path: "/Shared", folder_id: "f-root", is_folder: true, total_count: 3, offset: 0, count: 100,
          folders: [ { name: "Projects", path: "/Shared/Projects", folder_id: "f-1", is_folder: true },
                     { name: "Contracts", path: "/Shared/Contracts", folder_id: "f-2", is_folder: true } ],
          files: [ { name: "Read me.txt", path: "/Shared/Read me.txt", is_folder: false, size: 1023, entry_id: "e-1", group_id: "g-1",
                     last_modified: MODIFIED, uploaded_by: USERNAME, num_versions: 1 } ] }
      in [ :get, "/fs/Shared/Projects" ]
        { name: "Projects", path: "/Shared/Projects", folder_id: "f-1", is_folder: true, total_count: 1, offset: 0, count: 100,
          folders: [], files: [ { name: "Plan.pdf", path: "/Shared/Projects/Plan.pdf", is_folder: false, size: 52_000, entry_id: "e-2",
                                  group_id: "g-2", last_modified: MODIFIED, uploaded_by: USERNAME, num_versions: 2 } ] }
      in [ :post, %r{\A/fs-content/} ] then { checksum: headers["X-Sha512-Checksum"], entry_id: "e-up", group_id: "g-up" }
      else nil
      end
    answer ? [ 200, answer.to_json ] : [ 404, { errorMessage: "the stand-in does not answer #{method} #{path}" }.to_json ]
  end

  def self.install!
    Egnyte::OAuthClient.sign_in_stand_in = SignIn.new
    Egnyte::OAuthClient.http = Tokens.new
    Egnyte::Reader.http = READS
  end
end

if (Rails.env.development? && ENV["EGNYTE_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { EgnyteConnectStandIn.install! }
end
