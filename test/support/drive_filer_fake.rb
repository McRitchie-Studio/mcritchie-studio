# A fake Google Drive (and the bit of Gmail an attachment needs) for
# GoogleConnect::DriveFiler (/tasks/drive-filing). It keeps folders and files
# in memory, answers files.list for the query shapes DriveFiler sends
# (parent, name, folder type, and the appProperties mark), creates folders and
# files on POST, and takes a resumable upload's bytes on PUT. Every call is
# recorded. Set it as GoogleConnect::DriveFiler.http; no test reaches Google.
# Every name and byte here is invented.
class DriveFilerFake
  FOLDER = "application/vnd.google-apps.folder".freeze
  SESSION = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=session-1".freeze

  attr_reader :calls, :items, :tokens

  # items: what Drive already holds, each { "id", "name", "mimeType",
  # "parents", "appProperties", "md5Checksum" }. messages: { id => payload }
  # for Gmail's format=full read; attachments: { attachment id => bytes }.
  def initialize(items: [], messages: {}, attachments: {}, fail_with: nil)
    @items = items.map(&:dup)
    @messages = messages
    @attachments = attachments
    @fail_with = fail_with
    @calls = []
    @tokens = []
    @sessions = {}
  end

  def call(method, url, token, body, headers)
    @calls << [ method, url, body, headers ]
    @tokens << token
    return [ @fail_with, { error: { message: "Insufficient Permission" } }.to_json, {} ] if @fail_with

    case [ method, url ]
    in [ :get, %r{\Ahttps://gmail\.googleapis\.com/.+/messages/([^/?]+)\?format=full} ]
      [ 200, { id: Regexp.last_match(1), payload: @messages.fetch(Regexp.last_match(1)) }.to_json, {} ]
    in [ :get, %r{/messages/[^/]+/attachments/([^/?]+)\z} ]
      [ 200, { data: Base64.urlsafe_encode64(@attachments.fetch(Regexp.last_match(1))) }.to_json, {} ]
    in [ :get, %r{/drive/v3/files\?} ] then [ 200, { files: list(URI.decode_www_form(URI(url).query).to_h["q"]) }.to_json, {} ]
    in [ :post, /uploadType=multipart/ ] then [ 200, add(*multipart(body, headers)).to_json, {} ]
    in [ :post, /uploadType=resumable/ ]
      @sessions[SESSION] = JSON.parse(body)
      [ 200, "", { "Location" => SESSION } ]
    in [ :post, %r{/drive/v3/files\?} ] then [ 200, add(JSON.parse(body)).to_json, {} ]
    in [ :put, SESSION ] then [ 200, add(@sessions.fetch(SESSION), body).to_json, {} ]
    end
  end

  def writes = @calls.reject { _1.first == :get }
  def uploads = writes.select { _1[1].include?("/upload/") }
  def folders = @items.select { _1["mimeType"] == FOLDER }
  def queries = @calls.select { _1.first == :get && _1[1].include?("/drive/v3/files?") }.map { URI.decode_www_form(URI(_1[1]).query).to_h["q"] }

  private

  def list(query)
    parent = query[/'((?:[^'\\]|\\.)*)' in parents/, 1]
    name = query[/name = '((?:[^'\\]|\\.)*)'/, 1]&.gsub(/\\(.)/, '\1')
    @items.select do |item|
      Array(item["parents"]).include?(parent) &&
        (!query.include?("mimeType = '#{FOLDER}'") || item["mimeType"] == FOLDER) &&
        (name.nil? || item["name"] == name) &&
        (!query.include?("appProperties has { key='mcritchieFiler' and value='1' }") || item.dig("appProperties", "mcritchieFiler") == "1")
    end
  end

  def add(metadata, content = nil)
    item = metadata.merge("id" => "id-#{@items.size + 1}", "mimeType" => metadata["mimeType"] || "application/pdf",
                          "webViewLink" => "https://drive.google.com/file/d/id-#{@items.size + 1}/view")
    item["md5Checksum"] = Digest::MD5.hexdigest(content) if content
    @items << item
    item
  end

  # [metadata, content] out of a multipart/related body.
  def multipart(body, headers)
    boundary = headers.fetch("Content-Type")[/boundary=(\S+)/, 1]
    parts = body.b.split("--#{boundary}".b)[1..-2].map { _1.split("\r\n\r\n".b, 2).last.delete_suffix("\r\n".b) }
    [ JSON.parse(parts[0]), parts[1] ]
  end
end
