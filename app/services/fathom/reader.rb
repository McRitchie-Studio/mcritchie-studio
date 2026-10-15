require "net/http"
require "uri"
require "json"

module Fathom
  # Reads a connected Fathom account: its meetings, a meeting's transcript and
  # its summary. Every call is a GET with a bearer access token; no reader
  # holds a write path. Fathom says its own error plainly ("Fathom answered
  # 429: rate limited"), and the API allows about 60 requests a minute, so a
  # caller reads a page at a time.
  #
  # The access token comes from OAuthClient.access_token (one refresh, under
  # the row's lock) the first time a Reader needs it, and lives only as long as
  # the Reader. A caller that already holds a fresh access token (the callback,
  # straight from the code exchange) passes it as `token:` and spends no refresh.
  #
  # An OAuth app cannot ask /meetings for include_transcript or include_summary,
  # so each is its own call per recording.
  class Reader
    API_URL = "https://api.fathom.ai/external/v1".freeze

    Meeting = Struct.new(:recording_id, :title, :created_at, :url, :recorded_by, keyword_init: true)
    Page = Struct.new(:meetings, :next_cursor, keyword_init: true) do
      def more? = next_cursor.present?
    end
    Line = Struct.new(:speaker, :text, :timestamp, keyword_init: true)
    Transcript = Struct.new(:lines, keyword_init: true) do
      def speakers = lines.map(&:speaker).compact_blank.uniq
    end

    class << self
      # Stand-in for every read: (url, access_token) -> [status, body]. nil
      # means Fathom itself. Set in tests, the e2e lane and a local demo only.
      attr_accessor :http
    end

    def initialize(connection = nil, token: nil, oauth: OAuthClient)
      raise ArgumentError, "a Reader needs a connection or an access token" if connection.nil? && token.nil?

      @connection = connection
      @token = token
      @oauth = oauth
    end

    # One page of meetings, as Fathom orders them, and the cursor for the next.
    def meetings(cursor: nil)
      query = cursor.present? ? "?#{URI.encode_www_form(cursor:)}" : ""
      json = get_json("#{API_URL}/meetings#{query}")
      Page.new(meetings: Array(json["items"]).map { meeting(_1) }, next_cursor: json["next_cursor"].presence)
    end

    # The newest meeting on the first page (by created_at), or nil when there is none.
    def newest(page = meetings) = page.meetings.max_by { _1.created_at || Time.at(0) }

    def transcript(recording_id)
      json = get_json("#{API_URL}/recordings/#{ERB::Util.url_encode(recording_id.to_s)}/transcript")
      Transcript.new(lines: Array(json["transcript"]).map do |line|
        Line.new(speaker: line.dig("speaker", "display_name").to_s.presence, text: line["text"].to_s, timestamp: line["timestamp"])
      end)
    end

    # The summary as Fathom's markdown, or "" when the meeting has none.
    def summary(recording_id)
      get_json("#{API_URL}/recordings/#{ERB::Util.url_encode(recording_id.to_s)}/summary").dig("summary", "markdown_formatted").to_s
    end

    private

    def meeting(item)
      Meeting.new(recording_id: item["recording_id"], title: (item["title"].presence || item["meeting_title"].presence || "(untitled)").to_s,
                  created_at: parse_time(item["created_at"]), url: item["url"], recorded_by: item.dig("recorded_by", "email").presence)
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def token = (@token ||= @oauth.access_token(@connection))

    # The JSON of a 200, or OAuthClient::Error with Fathom's message.
    def get_json(url)
      status, body = get(url, token)
      json = JSON.parse(body.to_s) rescue {}
      json = {} unless json.is_a?(Hash)
      raise OAuthClient::Error, "Fathom answered #{status}: #{json['message'] || json['error'] || 'no detail'}" unless status == 200

      json
    end

    def get(url, token)
      return self.class.http.call(url, token) if self.class.http

      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "Fathom could not be reached: #{e.class}"
    end
  end
end
