require "net/http"
require "uri"
require "json"
require "securerandom"

module X
  # Net::HTTP wrapper that signs every request with X::OAuthSigner.
  # Knows how to issue the five request shapes we use:
  #   - get(url, query_params)
  #   - post_form(url, params)         — application/x-www-form-urlencoded
  #   - post_json(url, body)           — application/json
  #   - post_empty(url)                — no body (v2 media FINALIZE)
  #   - post_multipart(url, fields, media_chunk:) — for the chunked APPEND
  class Client
    class HttpError < StandardError; end

    def get(url, params = {})
      uri = URI(url)
      uri.query = URI.encode_www_form(params) if params.any?
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = OAuthSigner.header("GET", url, params)
      execute(uri, req)
    end

    def post_form(url, params)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = OAuthSigner.header("POST", url, params)
      req.set_form_data(params)
      execute(uri, req)
    end

    def post_json(url, body)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"]  = "application/json"
      # JSON bodies aren't part of the OAuth signature base string.
      req["Authorization"] = OAuthSigner.header("POST", url, {})
      req.body = JSON.generate(body)
      execute(uri, req)
    end

    # A bodiless POST. Nothing but the oauth_* params enters the signature.
    def post_empty(url)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = OAuthSigner.header("POST", url, {})
      execute(uri, req)
    end

    # multipart/form-data with named text fields plus a single binary `media` part.
    # OAuth signature base string is bare oauth_* params only — multipart fields
    # are excluded per Twitter's spec.
    def post_multipart(url, fields, media_chunk:)
      uri = URI(url)
      boundary = "----X#{SecureRandom.hex(12)}"
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"]  = "multipart/form-data; boundary=#{boundary}"
      req["Authorization"] = OAuthSigner.header("POST", url, {})
      req.body = build_multipart_body(fields, media_chunk, boundary)
      execute(uri, req)
    end

    # Parses a JSON response body, raising on non-2xx.
    def parse_json(resp)
      raise HttpError, "HTTP #{resp.code}: #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body || "{}")
    end

    private

    def execute(uri, req)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(req) }
    end

    def build_multipart_body(fields, media_chunk, boundary)
      out = +""
      fields.each do |k, v|
        out << "--#{boundary}\r\n"
        out << %{Content-Disposition: form-data; name="#{k}"\r\n\r\n}
        out << "#{v}\r\n"
      end
      out << "--#{boundary}\r\n"
      out << %{Content-Disposition: form-data; name="media"; filename="chunk.bin"\r\n}
      out << "Content-Type: application/octet-stream\r\n\r\n"
      out << media_chunk
      out << "\r\n--#{boundary}--\r\n"
      out
    end
  end
end
