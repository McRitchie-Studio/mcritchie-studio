require "net/http"

class DbBackupSweep
  # The two Heroku calls the sweep needs, over HTTPS with one bearer key
  # (ENV["HEROKU_BACKUP_API_KEY"]):
  #
  #   transfers(app)  GET  api.data.heroku.com/client/v11/apps/<app>/transfers
  #                   every backup, restore and copy the app's databases have run
  #   capture(app)    POST api.data.heroku.com/client/v11/databases/<add-on id>/backups
  #                   what `heroku pg:backups:capture -a <app>` sends; the add-on
  #                   id comes from the Platform API (api.heroku.com/apps/<app>/addons),
  #                   the heroku-postgresql add-on attached as DATABASE_URL
  #
  # Any failure raises Error with a SHORT reason fit for a report line or an
  # alert ("HTTP 401 key rejected", "timeout"); the key never appears in one.
  class HerokuClient
    Error = Class.new(StandardError)

    DATA_API = "https://api.data.heroku.com/client/v11".freeze
    PLATFORM_API = "https://api.heroku.com".freeze
    PLATFORM_ACCEPT = "application/vnd.heroku+json; version=3".freeze
    POSTGRES_SERVICE = "heroku-postgresql".freeze
    APP_NAME = /\A[a-z][a-z0-9-]{1,29}\z/
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    def initialize(token:, data_api: DATA_API, platform_api: PLATFORM_API,
                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      @token = token.to_s
      @data_api = data_api
      @platform_api = platform_api
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Array of transfer Hashes, newest or oldest first as Heroku returns them.
    def transfers(app)
      body = call(:get, "#{@data_api}/apps/#{name!(app)}/transfers")
      raise Error, "unexpected transfers body" unless body.is_a?(Array)

      body.grep(Hash)
    end

    # Starts a backup of the app's DATABASE_URL database; returns the transfer.
    def capture(app)
      addon = database_addon_id(app) or raise Error, "no #{POSTGRES_SERVICE} add-on on DATABASE_URL"
      call(:post, "#{@data_api}/databases/#{addon}/backups")
    end

    def database_addon_id(app)
      addons = call(:get, "#{@platform_api}/apps/#{name!(app)}/addons", accept: PLATFORM_ACCEPT)
      postgres = Array(addons).grep(Hash).select { |a| a.dig("addon_service", "name") == POSTGRES_SERVICE }
      chosen = postgres.find { |a| Array(a["config_vars"]).include?("DATABASE_URL") }
      chosen ||= postgres.first if postgres.one?
      chosen && chosen["id"].presence
    end

    private

    def name!(app)
      app.to_s.match?(APP_NAME) ? app.to_s : raise(Error, "bad Heroku app name")
    end

    def call(verb, url, accept: "application/json")
      uri = URI.parse(url)
      response = http_for(uri).request(build(verb, uri, accept))
      code = response.code.to_i
      case code
      when 200..299 then parse(response.body)
      when 401, 403 then raise Error, "HTTP #{code} key rejected"
      when 404 then raise Error, "HTTP 404 not found"
      when 429 then raise Error, "HTTP 429 rate limited"
      else raise Error, "HTTP #{code}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue *NETWORK_ERRORS => e
      raise Error, e.class.name.demodulize
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @open_timeout if http.respond_to?(:write_timeout=)
      http
    end

    def build(verb, uri, accept)
      request = (verb == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = accept
      request
    end

    def parse(body)
      body.to_s.strip.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      raise Error, "unparseable response"
    end
  end
end
