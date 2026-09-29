require "net/http"
require "json"
require "csv"
require "securerandom"

module Contacts
  # HTTP client for ZeroBounce email verification (task
  # verify-contacts-with-zerobounce). It uses the BULK file API: send one CSV of
  # addresses, poll its status, download the results. getcredits (free) reads
  # the balance; one credit is spent per address verified.
  #
  # Docs: https://www.zerobounce.net/docs/email-validation-api-quickstart/
  #   POST bulkapi/v2/sendfile   multipart: api_key, file, email_address_column
  #                              (1-based), has_header_row
  #                              -> {"success":true,"file_id":"…"}
  #   GET  bulkapi/v2/filestatus api_key, file_id
  #                              -> {"file_status":"Queued|Processing|Complete",…}
  #   GET  bulkapi/v2/getfile    api_key, file_id -> the results CSV
  #   GET  api/v2/getcredits     api_key -> {"Credits":"10100"} ("-1": bad key)
  # A failure answers {"success":false,"error_message":"…"}, getfile included.
  #
  # The key rides the query string or form, so no message this raises carries a
  # URL or a request, and any echo of the key is scrubbed.
  class ZeroBounce
    API_BASE = "https://api.zerobounce.net/v2".freeze
    BULK_BASE = "https://bulkapi.zerobounce.net/v2".freeze

    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 120

    class Error < StandardError; end

    # One address's verdict from a results file.
    Result = Data.define(:email, :status, :sub_status)

    def self.from_env
      new(api_key: ENV["ZEROBOUNCE_API_KEY"])
    end

    # `transport` takes (uri, request) and returns a Net::HTTPResponse-like
    # object (code, body, [content_type]); tests pass a fake.
    def initialize(api_key:, transport: nil)
      @api_key = api_key.to_s.strip
      raise Error, "ZEROBOUNCE_API_KEY is not set" if @api_key.empty?

      @transport = transport || method(:net_http)
    end

    # The credit balance, as an Integer.
    def credits
      body = json(get("#{API_BASE}/getcredits"))
      credits = Integer(body["Credits"] || body["credits"], exception: false)
      raise Error, "getcredits answered no balance" if credits.nil?
      raise Error, "getcredits refused the API key (balance -1)" if credits.negative?

      credits
    end

    # Submit `emails` as one bulk file; returns the file_id.
    def send_file(emails, name: "contacts-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}.csv")
      raise Error, "no emails to send" if emails.empty?

      csv = CSV.generate { |out| out << [ "email" ]; emails.each { |e| out << [ e ] } }
      fields = { "api_key" => @api_key, "email_address_column" => "1", "has_header_row" => "true",
                 "remove_duplicate" => "true" }
      boundary = "zb-#{SecureRandom.hex(12)}"
      req = Net::HTTP::Post.new(URI("#{BULK_BASE}/sendfile"))
      req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      req.body = multipart(fields, file: [ name, csv ], boundary: boundary)

      body = json(perform(URI("#{BULK_BASE}/sendfile"), req))
      body["file_id"].presence || raise(Error, "sendfile answered no file_id")
    end

    # The file's status hash (file_status, complete_percentage, …).
    def file_status(file_id)
      json(get("#{BULK_BASE}/filestatus", file_id: file_id))
    end

    # Whether the file has finished (file_status "Complete").
    def complete?(status)
      status["file_status"].to_s.strip.casecmp?("complete")
    end

    # The results file as Results. The CSV keeps our "email" column and adds
    # ZeroBounce's own; the status columns are found by header ("ZB Status",
    # "ZB Sub Status"), tolerant of case, spacing and underscores.
    def results(file_id)
      parse_results(get_file(file_id))
    end

    # The raw results file.
    def get_file(file_id)
      response = get("#{BULK_BASE}/getfile", file_id: file_id)
      body = response.body.to_s
      error!(JSON.parse(body)) if body.lstrip.start_with?("{")
      body
    rescue JSON::ParserError
      body
    end

    def parse_results(csv_text)
      rows = CSV.parse(csv_text.to_s.sub(/\A﻿/, ""), headers: true)
      headers = rows.headers.compact
      key = ->(h) { h.to_s.downcase.gsub(/[^a-z]/, "") }
      email_col = headers.find { |h| %w[email emailaddress].include?(key.(h)) } || headers.first
      status_col = headers.find { |h| %w[zbstatus status].include?(key.(h)) }
      sub_col = headers.find { |h| %w[zbsubstatus substatus].include?(key.(h)) }
      raise Error, "results file has no status column (headers: #{headers.join(", ")})" if status_col.nil?

      rows.filter_map do |row|
        email = row[email_col].to_s.strip.downcase
        next if email.empty?

        Result.new(email: email, status: row[status_col].to_s.strip.downcase, sub_status: sub_col && row[sub_col].to_s.strip.presence)
      end
    end

    private

    def get(url, **params)
      uri = URI(url)
      uri.query = URI.encode_www_form({ api_key: @api_key }.merge(params))
      perform(uri, Net::HTTP::Get.new(uri))
    end

    def perform(uri, request)
      response = @transport.call(uri, request)
      code = response.code.to_i
      return response if code.between?(200, 299)

      detail = begin
        JSON.parse(response.body.to_s)["error_message"]
      rescue JSON::ParserError, TypeError
        nil
      end
      raise Error, scrub("#{uri.host}#{uri.path} answered HTTP #{code}#{": #{detail}" if detail}")
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, scrub("#{uri.host}#{uri.path} unreachable: #{e.class}")
    end

    def json(response)
      body = JSON.parse(response.body.to_s)
      error!(body) if body.is_a?(Hash) && body["success"] == false
      body
    rescue JSON::ParserError
      raise Error, "ZeroBounce answered a body that is not JSON"
    end

    def error!(body)
      raise Error, scrub("ZeroBounce refused: #{body["error_message"] || body["message"] || "no message"}")
    end

    def scrub(message)
      message.gsub(@api_key, "[FILTERED]")
    end

    def multipart(fields, file:, boundary:)
      parts = fields.map do |name, value|
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      end
      filename, content = file
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
               "Content-Type: text/csv\r\n\r\n#{content}\r\n"
      parts.join + "--#{boundary}--\r\n"
    end

    def net_http(uri, request)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
    end
  end
end
