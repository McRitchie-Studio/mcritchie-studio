require "net/http"
require "uri"
require "json"

module GoogleConnect
  # What every read of a connected Google account shares: a fresh access
  # token from the connection's refresh token, a GET with it as the bearer,
  # and Google's own error message, said plainly ("Gmail answered 403: Gmail
  # API has not been used in project ... or it is disabled"). Every call is a
  # GET: no reader holds a write path. CalendarReader, GmailReader and
  # DriveReader each read one ability.
  class Reader
    class << self
      # Stand-in for every read: (url, access_token) -> [status, body]. nil
      # means Google itself. Set on Reader (subclasses read it there) in tests,
      # the e2e lane and a local demo only.
      attr_accessor :http

      def stand_in = Reader.http
    end

    # The product name an error message leads with.
    LABEL = "Google".freeze

    def initialize(connection, oauth: OAuthClient)
      @connection = connection
      @oauth = oauth
    end

    private

    def label = self.class::LABEL

    def token = (@token ||= @oauth.access_token(@connection))

    # The JSON of a 200, or OAuthClient::Error with Google's message.
    def get_json(url)
      status, body = get(url, token)
      json = JSON.parse(body.to_s) rescue {}
      raise OAuthClient::Error, "#{label} answered #{status}: #{json.dig('error', 'message') || 'no detail'}" unless status == 200

      json
    end

    def get(url, token)
      return self.class.stand_in.call(url, token) if self.class.stand_in

      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "#{label} could not be reached: #{e.class}"
    end
  end
end
