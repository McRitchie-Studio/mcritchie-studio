require "digest"
require "securerandom"

module GoogleConnect
  # Files documents into a connected account's Google Drive through the drive
  # ability's own drive.file grant (/tasks/drive-filing): it makes a folder
  # path (Insurance/Life Insurance), uploads a file into it, and files a Gmail
  # attachment there. No new scope: drive.file already lets an app create
  # folders and files and see only the ones it created (or the person picked).
  #
  # WHAT IT TOUCHES: only what it made. Every folder and file it creates
  # carries the appProperty MARK, and every lookup asks for that mark, so a
  # folder is reused only when the hub made it, and a file the person picked
  # is never seen here. Its only writes are a POST that creates a folder or a
  # file, and the PUT that sends a new file's bytes to the upload session
  # Google opened for it.
  #
  # WHAT IT NEVER DOES: delete, trash, share, change permissions, or change a
  # file that is already there. There is no method for any of it, and
  # drive_filer_test scans this source for the endpoints and verbs.
  #
  # DRY FIRST. Every call reads what is there and stops unless `apply: true`.
  # A dry run makes no folder and uploads nothing. Each call, dry or applied,
  # writes one DriveFiling (the audit log): the account, the folder path, the
  # file's name, size and md5, and the Drive id. Never the bytes, never the token.
  #
  # DriveFiler.http stands in for Google in tests:
  # (method, url, token, body, headers) -> [status, body, response headers].
  class DriveFiler < Reader
    LABEL = "Google Drive".freeze
    FILES_URL = "https://www.googleapis.com/drive/v3/files".freeze
    UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files".freeze
    GMAIL_URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages".freeze
    FOLDER_TYPE = "application/vnd.google-apps.folder".freeze
    # The mark on everything the hub creates, and the filter on every lookup.
    MARK_KEY = "mcritchieFiler".freeze
    MARK = { MARK_KEY => "1" }.freeze
    FIELDS = "id,name,mimeType,md5Checksum,webViewLink".freeze
    # Up to this many bytes go in one multipart request; more take a resumable session.
    MULTIPART_MAX = 5 * 1024 * 1024
    # The largest file one call files. The CLI carries the bytes over a
    # `heroku run` STDIN, so the cap keeps that pipe short.
    MAX_BYTES = 25 * 1024 * 1024
    MAX_DEPTH = 10
    MAX_NAME = 255
    # Only these hosts ever see the token: an upload session URL elsewhere is refused.
    GOOGLE_HOST = /\A(?:www|gmail)\.googleapis\.com\z/

    Error = Class.new(StandardError)
    # One upload, dry or applied. created_folders: the folders this call made
    # (applied) or would make (dry).
    Filed = Struct.new(:folder_path, :folder_id, :name, :md5, :byte_size, :source, :drive_file_id, :url,
                       :applied, :duplicate, :created_folders, keyword_init: true)

    class << self
      # Stand-in for every call: (method, url, token, body, headers) -> [status, body, response headers].
      attr_accessor :http
    end

    def initialize(connection, requested_by:, oauth: OAuthClient)
      super(connection, oauth:)
      @requested_by = requested_by.to_s.presence || raise(Error, "a Drive write needs requested_by")
      return if connection.drive_picked?

      raise Error, "#{connection.email} has not connected Google Drive (/integrations)." unless connection.can?(:drive)

      raise Error, "#{connection.email} holds Google's older Drive permission; reconnect Drive at /integrations to file documents."
    end

    # Makes the folder path, reusing each folder the hub already made there.
    # Dry unless apply: then it only says which folders it would make.
    def mkdir(path, apply: false)
      segments = segments_of(path)
      folder_id, created, missing = resolve(segments, create: apply)
      log!(action: "mkdir", folder_path: segments.join("/"), drive_file_id: folder_id, applied: apply)
      { "folder_path" => segments.join("/"), "folder_id" => folder_id, "created" => created,
        "would_create" => missing, "applied" => apply }
    rescue OAuthClient::Error => e
      log!(action: "mkdir", folder_path: segments.join("/"), applied: apply, error: e.message) if segments
      raise
    end

    # Files `content` (the bytes) as `name` in the folder path, making the
    # path as #mkdir does. A file with the same md5 already in that folder (one
    # the hub filed) is not uploaded again: the answer names it as a duplicate.
    # `expected_md5`, when given, must match the bytes (the CLI sends its own).
    def upload(name:, content:, folder:, source: "local", apply: false, expected_md5: nil)
      name = file_name(name)
      content = content.to_s.b
      raise Error, "the file is empty" if content.empty?
      raise Error, "the file is #{content.bytesize} bytes; the most one call files is #{MAX_BYTES}" if content.bytesize > MAX_BYTES

      md5 = Digest::MD5.hexdigest(content)
      raise Error, "the bytes arrived changed (md5 mismatch); nothing was filed" if expected_md5.present? && expected_md5 != md5

      segments = segments_of(folder)
      folder_id, created, missing = resolve(segments, create: apply)
      existing = folder_id && same_file(folder_id, md5)
      sent = apply && !existing ? send_file(name, content, folder_id) : nil
      file = existing || sent || {}
      filed = Filed.new(folder_path: segments.join("/"), folder_id:, name:, md5:, byte_size: content.bytesize, source:,
                        drive_file_id: file["id"], url: file["webViewLink"], applied: apply, duplicate: existing.present?,
                        created_folders: apply ? created : missing)
      log!(action: "upload", folder_path: filed.folder_path, file_name: name, md5:, byte_size: content.bytesize, source:,
           drive_file_id: filed.drive_file_id, applied: apply, duplicate: filed.duplicate)
      filed
    rescue OAuthClient::Error => e
      if segments
        log!(action: "upload", folder_path: segments.join("/"), file_name: name, md5:, byte_size: content.bytesize, source:,
             applied: apply, error: e.message)
      end
      raise
    end

    # Files one attachment of a Gmail message, read with the same account's
    # Gmail read grant (refused when it has none). `name` picks the attachment
    # by its file name; a message with several needs it. `as` renames it in Drive.
    def file_attachment(message_id:, folder:, name: nil, as: nil, apply: false)
      unless @connection.can?(:gmail) || @connection.can?(:gmail_organize)
        raise Error, "#{@connection.email} has not connected Gmail (/integrations); its attachments cannot be read."
      end
      raise Error, "not a Gmail message id" unless message_id.to_s.match?(/\A[\w-]+\z/)

      part = attachment_part(message_id.to_s, name)
      upload(name: as.presence || part[:filename], content: attachment_bytes(message_id.to_s, part), folder:, source: "gmail", apply:)
    end

    # What the hub made in the folder path (My Drive's top when blank):
    # [{ "id", "name", "mimeType", "md5Checksum", "webViewLink" }]. Nothing
    # when the path is not there (or the hub did not make it).
    def list(path = nil)
      parent = path.to_s.strip.empty? ? "root" : resolve(segments_of(path), create: false).first
      return [] if parent.nil?

      children(parent)
    end

    private

    # "Insurance/Life Insurance" -> ["Insurance", "Life Insurance"], each a
    # plain name: no empty part, no . or .., no control character.
    def segments_of(path)
      segments = path.to_s.split("/").map(&:strip).reject(&:empty?)
      raise Error, "a folder path is required (for example: Insurance/Life Insurance)" if segments.empty?
      raise Error, "a folder path is at most #{MAX_DEPTH} folders deep" if segments.size > MAX_DEPTH

      segments.each { plain_name!(_1, "folder") }
    end

    def file_name(name)
      plain_name!(File.basename(name.to_s.strip), "file")
    end

    def plain_name!(name, kind)
      raise Error, "a #{kind} name is required" if name.empty?
      raise Error, "#{kind} name #{name.inspect} is not a plain name" if %w[. ..].include?(name) || name.match?(/[[:cntrl:]]/)
      raise Error, "a #{kind} name is at most #{MAX_NAME} characters" if name.length > MAX_NAME

      name
    end

    # [the deepest folder's id or nil, folders made, folders missing]. Walks
    # the path from My Drive's top, reusing each folder the hub made; with
    # create it makes the missing ones, without it it stops at the first.
    def resolve(segments, create:)
      parent = "root"
      created = []
      segments.each_with_index do |segment, index|
        found = child_folder(parent, segment)
        if found.nil? && !create
          return [ nil, [], segments[index..].each_with_index.map { |_, i| segments[0..index + i].join("/") } ]
        end

        if found.nil?
          found = create_folder(segment, parent)
          created << segments[0..index].join("/")
        end
        parent = found["id"]
      end
      [ parent, created, [] ]
    end

    def child_folder(parent, name)
      query = "#{marked_in(parent)} and mimeType = '#{FOLDER_TYPE}' and name = '#{quote(name)}'"
      find_files(query).first
    end

    # The file the hub filed in the folder with this md5, or nil.
    def same_file(folder_id, md5)
      children(folder_id).find { _1["md5Checksum"] == md5 }
    end

    def children(parent) = find_files(marked_in(parent))

    def marked_in(parent)
      "'#{quote(parent)}' in parents and trashed = false and appProperties has { key='#{MARK_KEY}' and value='1' }"
    end

    def find_files(query)
      files = []
      page = nil
      loop do
        params = { q: query, fields: "nextPageToken,files(#{FIELDS})", pageSize: 100, orderBy: "createdTime" }
        params[:pageToken] = page if page
        json = call_json(:get, "#{FILES_URL}?#{URI.encode_www_form(params)}")
        files.concat(Array(json["files"]))
        page = json["nextPageToken"]
        return files if page.nil?
      end
    end

    # Drive's query language quotes with ' and escapes with \.
    def quote(text) = text.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }

    def create_folder(name, parent)
      body = { name:, mimeType: FOLDER_TYPE, parents: [ parent ], appProperties: MARK }.to_json
      call_json(:post, "#{FILES_URL}?#{URI.encode_www_form(fields: FIELDS)}", body, "Content-Type" => "application/json")
    end

    def send_file(name, content, folder_id)
      metadata = { name:, parents: [ folder_id ], appProperties: MARK }
      type = Marcel::MimeType.for(StringIO.new(content), name:)
      content.bytesize <= MULTIPART_MAX ? multipart(metadata, content, type) : resumable(metadata, content, type)
    end

    def multipart(metadata, content, type)
      boundary = "drive-filer-#{SecureRandom.hex(12)}"
      body = +"".b
      body << "--#{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n#{metadata.to_json}\r\n".b
      body << "--#{boundary}\r\nContent-Type: #{type}\r\n\r\n".b << content << "\r\n--#{boundary}--".b
      call_json(:post, "#{UPLOAD_URL}?#{URI.encode_www_form(uploadType: 'multipart', fields: FIELDS)}", body,
                "Content-Type" => "multipart/related; boundary=#{boundary}")
    end

    # Opens a resumable session, then sends the bytes to it in one PUT.
    def resumable(metadata, content, type)
      status, text, headers = call(:post, "#{UPLOAD_URL}?#{URI.encode_www_form(uploadType: 'resumable', fields: FIELDS)}", metadata.to_json,
                                   "Content-Type" => "application/json; charset=UTF-8", "X-Upload-Content-Type" => type,
                                   "X-Upload-Content-Length" => content.bytesize.to_s)
      raise_unless_ok!(status, text)
      session = headers.to_h.transform_keys { _1.to_s.downcase }["location"].to_s
      raise OAuthClient::Error, "#{label} opened no upload session" unless google_url?(session) && session.start_with?(UPLOAD_URL)

      call_json(:put, session, content, "Content-Type" => type)
    end

    # The message's attachment parts: { filename:, attachment_id:, data: }.
    def attachment_part(message_id, name)
      json = call_json(:get, "#{GMAIL_URL}/#{message_id}?#{URI.encode_www_form(format: 'full')}", label: "Gmail")
      parts = attachment_parts(json["payload"])
      raise Error, "that message has no attachments" if parts.empty?

      if name.present?
        parts.find { _1[:filename].casecmp?(name.to_s.strip) } ||
          raise(Error, "no attachment named #{name.to_s.strip.inspect}; it has #{parts.map { _1[:filename] }.join(', ')}")
      elsif parts.size == 1
        parts.first
      else
        raise Error, "that message has #{parts.size} attachments; name one with --name (#{parts.map { _1[:filename] }.join(', ')})"
      end
    end

    def attachment_parts(part)
      return [] unless part.is_a?(Hash)

      own = part["filename"].present? ? [ { filename: part["filename"], attachment_id: part.dig("body", "attachmentId"), data: part.dig("body", "data") } ] : []
      own + Array(part["parts"]).flat_map { attachment_parts(_1) }
    end

    def attachment_bytes(message_id, part)
      data = part[:data].presence ||
             call_json(:get, "#{GMAIL_URL}/#{message_id}/attachments/#{URI.encode_www_form_component(part[:attachment_id].to_s)}", label: "Gmail")["data"]
      Base64.urlsafe_decode64(data.to_s)
    end

    def call_json(method, url, body = nil, headers = {}, label: self.label)
      status, text, = call(method, url, body, headers)
      raise_unless_ok!(status, text, label:)
      JSON.parse(text.to_s.presence || "{}")
    end

    def raise_unless_ok!(status, text, label: self.label)
      return if (200..299).cover?(status)

      json = JSON.parse(text.to_s) rescue {}
      raise OAuthClient::Error, "#{label} answered #{status}: #{json.dig('error', 'message') || 'no detail'}"
    end

    def google_url?(url)
      uri = URI(url)
      uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(GOOGLE_HOST)
    rescue URI::InvalidURIError
      false
    end

    # The one way out: GET, POST or PUT, to Google only.
    def call(method, url, body = nil, headers = {})
      raise ArgumentError, "DriveFiler sends only GET, POST and PUT" unless %i[get post put].include?(method)
      raise ArgumentError, "DriveFiler calls Google only" unless google_url?(url)
      return self.class.http.call(method, url, token, body, headers) if self.class.http

      uri = URI(url)
      request = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method).new(uri)
      headers.each { |key, value| request[key] = value }
      request["Authorization"] = "Bearer #{token}"
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) { _1.request(request) }
      [ response.code.to_i, response.body, response.each_header.to_h ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "#{label} could not be reached: #{e.class}"
    end

    def log!(action:, folder_path:, applied:, file_name: nil, md5: nil, byte_size: nil, source: nil, drive_file_id: nil,
             duplicate: false, error: nil)
      DriveFiling.create!(mailbox: @connection.email, action:, folder_path:, file_name:, md5:, byte_size:, source:,
                          drive_file_id:, applied:, duplicate:, requested_by: @requested_by, error:)
    end
  end
end
