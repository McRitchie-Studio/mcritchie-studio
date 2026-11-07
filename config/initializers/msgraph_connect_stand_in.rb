# frozen_string_literal: true

# THE STAND-IN FOR MICROSOFT when the Microsoft 365 connection is walked
# without an Entra app registration: the e2e lane (it rides the lane's
# E2E_FAKE_VIDEO_STORAGE marker, as the Fathom, Google and TikTok stand-ins do)
# and a local demo (MSGRAPH_STAND_IN=1, development only: a desk's .env also
# loads under the test environment, where the flag would hijack the unit
# tests). NEVER in production.
#
# Microsoft's admin-consent page comes straight back to the callback with a
# synthetic tenant and admin_consent=True. The token endpoint is stood in at
# the HTTP layer (Msgraph::OAuthClient.http), so the real client-credentials
# request and the in-memory token cache run; it counts the tokens it issues.
# The reads answer a synthetic organization, three users, two Teams, a root
# site and two drives. The callback, the stored MsgraphConnection and the
# pages are real. The real request shapes are pinned by test/services/msgraph/.
module MsgraphConnectStandIn
  # Synthetic: the all-zero GUID's neighbour, never a real tenant.
  TENANT = "00000000-0000-0000-0000-00000000c0de"
  ORGANIZATION = "Stand-in Tenant"
  SITE_ID = "stand-in.sharepoint.example,1,2"

  class SignIn
    def authorize_url(redirect_uri:, state:) = "#{redirect_uri}?#{URI.encode_www_form(tenant: TENANT, state:, admin_consent: 'True')}"
  end

  # The token endpoint: (url, form) -> [status, body].
  class Tokens
    attr_reader :issued

    def initialize
      @issued = 0
      @lock = Mutex.new
    end

    def call(url, form)
      @lock.synchronize do
        next [ 400, { error: "unsupported_grant_type" }.to_json ] unless form[:grant_type] == "client_credentials"
        next [ 400, { error: "unauthorized_client", error_description: "AADSTS700016: not in this stand-in tenant" }.to_json ] unless url.include?("/#{TENANT}/")

        @issued += 1
        [ 200, { token_type: "Bearer", expires_in: 3599, access_token: "stand-in-graph-#{SecureRandom.hex(8)}" }.to_json ]
      end
    end
  end

  READS = lambda do |url, _token|
    path = url.delete_prefix(Msgraph::Reader::API_URL)
    body =
      case path
      when "/organization/#{TENANT}" then { id: TENANT, displayName: ORGANIZATION }
      when %r{\A/users}
        { value: [
          { id: "u1", displayName: "Stand In", userPrincipalName: "stand.in@stand-in.example", mail: "stand.in@stand-in.example" },
          { id: "u2", displayName: "Second Seat", userPrincipalName: "second@stand-in.example", mail: nil },
          { id: "u3", displayName: "Third Seat", userPrincipalName: "third@stand-in.example", mail: nil }
        ], "@odata.nextLink": "#{Msgraph::Reader::API_URL}/users?$skiptoken=stand-in" }
      when "/teams"
        { value: [ { id: "t1", displayName: "Shop Floor", description: "Stand-in team", visibility: "private" },
                   { id: "t2", displayName: "Office", description: nil, visibility: "public" } ] }
      when "/sites/root" then { id: SITE_ID, displayName: "Communication site", webUrl: "https://stand-in.sharepoint.example" }
      when "/sites/#{ERB::Util.url_encode(SITE_ID)}/drives"
        { value: [ { id: "d1", name: "Documents", driveType: "documentLibrary", webUrl: "https://stand-in.sharepoint.example/Shared%20Documents" },
                   { id: "d2", name: "Drawings", driveType: "documentLibrary", webUrl: "https://stand-in.sharepoint.example/Drawings" } ] }
      end
    body ? [ 200, body.to_json ] : [ 404, { error: { code: "itemNotFound", message: "the stand-in does not answer #{path}" } }.to_json ]
  end

  def self.install!
    Msgraph::OAuthClient.sign_in_stand_in = SignIn.new
    Msgraph::OAuthClient.http = Tokens.new
    Msgraph::Reader.http = READS
  end
end

if (Rails.env.development? && ENV["MSGRAPH_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { MsgraphConnectStandIn.install! }
end
