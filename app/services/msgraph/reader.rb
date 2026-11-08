require "net/http"
require "uri"
require "json"

module Msgraph
  # Reads a connected Microsoft 365 tenant through Microsoft Graph v1.0, app-only:
  # its organization's name, its users, its Teams, and a SharePoint site's
  # drives (document libraries). Every call is a GET with a bearer token; no
  # reader holds a write path. Graph says its own error plainly ("Microsoft
  # Graph answered 403: Insufficient privileges").
  #
  # Each call and the least-privileged Application permission Microsoft lists
  # for it (learn.microsoft.com/graph/api/<page>?view=graph-rest-1.0):
  #   organization  GET /organization/{id}   Organization.Read.All  (organization-get)
  #   users         GET /users               User.Read.All          (user-list)
  #   teams         GET /teams               Team.ReadBasic.All     (teams-list)
  #   root_site     GET /sites/root          Sites.Read.All         (site-get)
  #   drives        GET /sites/{id}/drives   Files.Read.All         (drive-list)
  #
  # A list answers one page (`value`) and, when there is more, an
  # @odata.nextLink: the Page carries it so a caller reads a page at a time.
  # The token comes from OAuthClient.access_token (cached in memory per tenant).
  class Reader
    API_URL = "https://graph.microsoft.com/v1.0".freeze
    # Graph's documented page sizes: users default 100, max 999.
    PAGE_SIZE = 100

    Organization = Struct.new(:id, :display_name, keyword_init: true)
    User = Struct.new(:id, :display_name, :user_principal_name, :mail, keyword_init: true)
    Team = Struct.new(:id, :display_name, :description, :visibility, keyword_init: true)
    Site = Struct.new(:id, :display_name, :web_url, keyword_init: true)
    Drive = Struct.new(:id, :name, :drive_type, :web_url, keyword_init: true)
    Page = Struct.new(:items, :next_link, keyword_init: true) do
      def more? = next_link.present?
    end

    class << self
      # Stand-in for every read: (url, access_token) -> [status, body]. nil
      # means Microsoft itself. Set in tests, the e2e lane and a local demo only.
      attr_accessor :http
    end

    # `connection` is an MsgraphConnection (its tenant id names the tenant);
    # `tenant_id:` reads a tenant before its row exists (the consent callback).
    def initialize(connection = nil, tenant_id: nil, oauth: OAuthClient)
      @tenant_id = tenant_id || connection&.tenant_id
      raise ArgumentError, "a Reader needs a connection or a tenant id" if @tenant_id.blank?

      @oauth = oauth
    end

    def organization
      json = get_json("#{API_URL}/organization/#{ERB::Util.url_encode(@tenant_id)}")
      Organization.new(id: json["id"], display_name: json["displayName"].to_s.presence)
    end

    # One page of users; pass the previous page's next_link for the next.
    def users(next_link: nil)
      page(next_link || "#{API_URL}/users?#{URI.encode_www_form('$select' => 'id,displayName,userPrincipalName,mail', '$top' => PAGE_SIZE)}") do |item|
        User.new(id: item["id"], display_name: item["displayName"], user_principal_name: item["userPrincipalName"], mail: item["mail"])
      end
    end

    # One page of the tenant's Teams. Graph fills only id, displayName,
    # description and visibility on this list.
    def teams(next_link: nil)
      page(next_link || "#{API_URL}/teams") do |item|
        Team.new(id: item["id"], display_name: item["displayName"], description: item["description"], visibility: item["visibility"])
      end
    end

    # The tenant's root SharePoint site.
    def root_site
      json = get_json("#{API_URL}/sites/root")
      Site.new(id: json["id"], display_name: json["displayName"], web_url: json["webUrl"])
    end

    # One page of a site's drives (its document libraries).
    def drives(site_id, next_link: nil)
      page(next_link || "#{API_URL}/sites/#{ERB::Util.url_encode(site_id.to_s)}/drives") do |item|
        Drive.new(id: item["id"], name: item["name"], drive_type: item["driveType"], web_url: item["webUrl"])
      end
    end

    private

    def page(url, &build)
      json = get_json(url)
      Page.new(items: Array(json["value"]).map(&build), next_link: json["@odata.nextLink"].presence)
    end

    def token = (@token ||= @oauth.access_token(@tenant_id))

    # The JSON of a 200, or OAuthClient::Error with Graph's message. A next
    # link is followed only when it is Graph's own.
    def get_json(url)
      raise OAuthClient::Error, "refusing a link outside Microsoft Graph" unless url.start_with?("#{API_URL}/")

      status, body = get(url, token)
      json = JSON.parse(body.to_s) rescue {}
      json = {} unless json.is_a?(Hash)
      raise OAuthClient::Error, "Microsoft Graph answered #{status}: #{json.dig('error', 'message') || json.dig('error', 'code') || 'no detail'}" unless status == 200

      json
    end

    def get(url, token)
      return self.class.http.call(url, token) if self.class.http

      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "Microsoft Graph could not be reached: #{e.class}"
    end
  end
end
