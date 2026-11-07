require "net/http"
require "uri"
require "json"
require "digest"

module Egnyte
  # Reads, and writes one file to, a connected Egnyte domain through its Public
  # API (https://<domain>.egnyte.com/pubapi/v1, Egnyte's File System docs, read
  # 2026-11-06):
  #
  #   #whoami         who the token belongs to (GET /pubapi/v1/whoami; no scope)
  #   #folder(path)   one page of a folder's subfolders and files (GET /fs/<path>?list_content=true)
  #   #metadata(path) one file's or folder's metadata (GET /fs/<path>)
  #   #upload(path, content)  the ONLY write: one file, at most SIMPLE_UPLOAD_LIMIT (POST /fs-content/<path>)
  #   #each_entry(path)       every entry of one folder, page by page
  #
  # THE BULK IMPORT IS A FOLLOW-UP. #each_entry is its seam: an import job walks
  # a folder with it, recurses into each folder Entry, and copies each file
  # Entry (a download read and the chunked upload endpoint,
  # /fs-content-chunked, for files over 100 MB, are its to add). Nothing here
  # walks a tree or moves a file on its own.
  #
  # LIMITS. Egnyte allows about 2 calls a second and 1,000 a day per access
  # token; a 429 raises OAuthClient::RateLimited, said plainly on the page. A
  # caller reads a page at a time.
  #
  # PATHS. Each segment is URL-encoded on its own and the slashes are not
  # (Egnyte's rule). A "." or ".." segment is refused rather than sent.
  #
  # The access token comes from OAuthClient.access_token (the stored one while
  # fresh) the first time a Reader needs it; a 401 refreshes it once and
  # retries. The callback, holding a token straight from the code exchange,
  # passes `domain:` and `token:` and spends no refresh.
  class Reader
    API_PATH = "/pubapi/v1".freeze
    # Egnyte recommends its chunked upload above this size; #upload refuses it.
    SIMPLE_UPLOAD_LIMIT = 100 * 1024 * 1024
    PAGE_SIZE = 100
    ROOT = "/Shared".freeze

    Entry = Struct.new(:name, :path, :folder, :size, :last_modified, :uploaded_by, :entry_id, :group_id, :folder_id,
                       :checksum, :num_versions, keyword_init: true) do
      def folder? = folder == true
    end
    Folder = Struct.new(:name, :path, :folder_id, :folders, :files, :total_count, :offset, keyword_init: true) do
      def entries = folders + files
      # Egnyte counts subfolders and files together in total_count.
      def more? = total_count.to_i > offset.to_i + entries.size
    end

    class << self
      # Stand-in for every API call: ->(method:, url:, token:, body:, headers:)
      # -> [status, body]. nil means Egnyte itself. Set in tests, the e2e lane
      # and a local demo only.
      attr_accessor :http

      # "/Shared/a b/c?d" -> "/Shared/a%20b/c%3Fd". Raises ArgumentError on an
      # empty path or a dot segment.
      def encode_path(path)
        segments = path.to_s.split("/").reject(&:empty?)
        raise ArgumentError, "an Egnyte path names at least one folder" if segments.empty?
        raise ArgumentError, "an Egnyte path may not hold . or .. segments" if segments.any? { %w[. ..].include?(_1) }

        "/" + segments.map { ERB::Util.url_encode(_1) }.join("/")
      end
    end

    def initialize(connection = nil, domain: nil, token: nil, oauth: OAuthClient)
      raise ArgumentError, "a Reader needs a connection, or a domain and an access token" if connection.nil? && (domain.nil? || token.nil?)

      @connection = connection
      @domain = connection&.domain || domain
      @token = token
      @oauth = oauth
    end

    # The Egnyte username the token belongs to, or nil when Egnyte names none.
    def whoami = request(:get, "/whoami")["username"].presence

    def folder(path = ROOT, offset: 0, count: PAGE_SIZE)
      query = URI.encode_www_form(list_content: true, count:, offset:)
      json = request(:get, "/fs#{self.class.encode_path(path)}?#{query}")
      raise OAuthClient::Error, "#{path} is a file, not a folder" if json.key?("is_folder") && json["is_folder"] != true

      Folder.new(name: json["name"], path: json["path"] || path, folder_id: json["folder_id"],
                 folders: Array(json["folders"]).map { entry(_1, folder: true) },
                 files: Array(json["files"]).map { entry(_1, folder: false) },
                 total_count: json["total_count"].to_i, offset: json["offset"].to_i)
    end

    def metadata(path) = entry(request(:get, "/fs#{self.class.encode_path(path)}"))

    # Every subfolder and file of one folder (not deeper), a page per call.
    def each_entry(path = ROOT, count: PAGE_SIZE)
      return enum_for(:each_entry, path, count:) unless block_given?

      offset = 0
      loop do
        page = folder(path, offset:, count:)
        page.entries.each { yield _1 }
        break if page.entries.empty? || !page.more?

        offset += page.entries.size
      end
    end

    # Uploads one file to `path` (the folder and the file's name), replacing a
    # file already there with a new version, as Egnyte does. The body is the
    # raw bytes with their SHA-512, which Egnyte checks. Answers the stored
    # file's Entry, as far as Egnyte describes it.
    def upload(path, content, last_modified: nil)
      bytes = content.respond_to?(:read) ? content.read : content.to_s
      raise ArgumentError, "a file over #{SIMPLE_UPLOAD_LIMIT / 1.megabyte} MB needs Egnyte's chunked upload" if bytes.bytesize > SIMPLE_UPLOAD_LIMIT

      encoded = self.class.encode_path(path)
      headers = { "Content-Type" => "application/octet-stream", "X-Sha512-Checksum" => Digest::SHA512.hexdigest(bytes) }
      headers["Last-Modified"] = last_modified.httpdate if last_modified
      json = request(:post, "/fs-content#{encoded}", body: bytes, headers:, ok: [ 200, 201 ])
      clean = "/" + path.to_s.split("/").reject(&:empty?).join("/")
      entry({ "name" => File.basename(clean), "path" => clean, "size" => bytes.bytesize }.merge(json), folder: false)
    end

    private

    def entry(item, folder: nil)
      Entry.new(name: item["name"], path: item["path"], folder: folder.nil? ? item["is_folder"] == true : folder,
                size: item["size"], last_modified: parse_time(item["last_modified"] || item["lastModified"]),
                uploaded_by: item["uploaded_by"], entry_id: item["entry_id"], group_id: item["group_id"],
                folder_id: item["folder_id"], checksum: item["checksum"], num_versions: item["num_versions"])
    end

    # Egnyte gives HTTP dates for files and epoch milliseconds for folders.
    def parse_time(value)
      case value
      when Integer then Time.zone.at(value / 1000.0)
      when String then value.match?(/\A\d+\z/) ? Time.zone.at(value.to_i / 1000.0) : Time.zone.parse(value)
      end
    rescue ArgumentError
      nil
    end

    def token = (@token ||= @oauth.access_token(@connection))

    # The JSON of an ok answer, or an OAuthClient error with Egnyte's message.
    # A 401 on a connection refreshes the token once and retries.
    def request(method, path, body: nil, headers: {}, ok: [ 200 ], retried: false)
      url = "#{@oauth.base_url(@domain)}#{API_PATH}#{path}"
      status, response = call(method, url, token, body, headers)
      if status == 401 && @connection && !retried
        @token = @oauth.access_token(@connection, stale: @token)
        return request(method, path, body:, headers:, ok:, retried: true)
      end

      json = JSON.parse(response.to_s) rescue {}
      json = {} unless json.is_a?(Hash)
      return json if ok.include?(status)

      detail = json["errorMessage"] || json["message"] || Array(json["errors"] || json["Errors"]).filter_map { _1["description"] if _1.is_a?(Hash) }.first || json["error"]
      raise OAuthClient::RateLimited, "Egnyte is rate limiting this connection (#{status}); about 2 calls a second and 1,000 a day are allowed" if status == 429
      raise OAuthClient::Revoked, "Egnyte no longer accepts this connection (#{status}); connect again" if status == 401

      raise OAuthClient::Error, "Egnyte answered #{status}: #{detail || 'no detail'}"
    end

    def call(method, url, token, body, headers)
      return self.class.http.call(method:, url:, token:, body:, headers:) if self.class.http

      uri = URI(url)
      request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      request["Authorization"] = "Bearer #{token}"
      headers.each { |name, value| request[name] = value }
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "Egnyte could not be reached: #{e.class}"
    end
  end
end
