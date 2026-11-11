# A fake Gmail for GoogleConnect::GmailEditor (/tasks/gmail-organize-ability):
# pages of message ids, labels, and every write recorded. Set it as
# GoogleConnect::GmailEditor.http; no test reaches Google.
class GmailEditorFake
  attr_reader :calls, :labels

  # headers: { message id => { "From" => ..., "List-Unsubscribe" => ... } }
  # for GmailEditor#unsubscribe's format=metadata reads.
  def initialize(ids: [], labels: [ { "id" => "Label_1", "name" => "Receipts", "type" => "user" } ], fail_with: nil, headers: {})
    @ids = ids
    @headers = headers
    @labels = labels.dup
    @calls = []
    @fail_with = fail_with
  end

  def call(method, url, _token, body)
    @calls << [ method, url, body && JSON.parse(body) ]
    return [ @fail_with, { error: { message: "Insufficient Permission" } }.to_json ] if @fail_with

    case [ method, url ]
    in [ :get, /\/messages\?/ ] then list(url)
    in [ :get, %r{/messages/[^/?]+\?format=metadata} ]
      id = url[%r{/messages/([^/?]+)\?}, 1]
      headers = @headers.fetch(id, {}).map { |name, value| { name:, value: } }
      [ 200, { id:, payload: { headers: } }.to_json ]
    in [ :get, /\/labels\z/ ] then [ 200, { labels: @labels }.to_json ]
    in [ :post, /\/labels\z/ ]
      made = { "id" => "Label_#{@labels.size + 1}", "name" => JSON.parse(body)["name"], "type" => "user" }
      @labels << made
      [ 200, made.to_json ]
    in [ :post, /batchModify\z/ ] then [ 204, "" ]
    in [ :post, /settings\/filters\z/ ] then [ 200, { id: "filter-1" }.to_json ]
    in [ :get, /settings\/filters\z/ ] then [ 200, { filter: [ { id: "filter-1" } ] }.to_json ]
    end
  end

  def writes = @calls.select { _1.first == :post }
  def modifies = writes.select { _1[1].end_with?("batchModify") }

  private

  # PAGE ids per page; the page token is the offset.
  def list(url)
    params = URI.decode_www_form(URI(url).query).to_h
    from = params["pageToken"].to_i
    size = params["maxResults"].to_i
    slice = @ids[from, size] || []
    nxt = from + size < @ids.size ? (from + size).to_s : nil
    [ 200, { messages: slice.map { { id: _1 } }, nextPageToken: nxt }.compact.to_json ]
  end
end
