require "test_helper"

# [unit] Contacts::ZeroBounce against a fake transport: no request leaves the
# process. Pins the endpoints and parameters the bulk docs name, the parsing of
# credits, file status and the results file, and that errors surface without
# the key.
class Contacts::ZeroBounceTest < ActiveSupport::TestCase
  KEY = "zb-test-key-0123456789".freeze

  Response = Struct.new(:code, :body)

  # A transport answering from a queue of [code, body], recording each request.
  def client(*answers)
    @calls = []
    transport = lambda do |uri, req|
      @calls << { uri: uri, req: req }
      code, body = answers.shift || [ 200, "{}" ]
      Response.new(code.to_s, body)
    end
    Contacts::ZeroBounce.new(api_key: KEY, transport: transport)
  end

  def query(call) = URI.decode_www_form(call[:uri].query.to_s).to_h

  test "refuses to build without a key" do
    error = assert_raises(Contacts::ZeroBounce::Error) { Contacts::ZeroBounce.new(api_key: " ") }
    assert_match "ZEROBOUNCE_API_KEY", error.message
  end

  test "from_env reads ZEROBOUNCE_API_KEY" do
    ENV["ZEROBOUNCE_API_KEY"] = KEY
    assert_kind_of Contacts::ZeroBounce, Contacts::ZeroBounce.from_env
  ensure
    ENV.delete("ZEROBOUNCE_API_KEY")
  end

  test "credits reads the balance from getcredits" do
    zb = client([ 200, { "Credits" => "10100" }.to_json ])
    assert_equal 10_100, zb.credits
    call = @calls.first
    assert_equal "api.zerobounce.net", call[:uri].host
    assert_equal "/v2/getcredits", call[:uri].path
    assert_equal KEY, query(call)["api_key"]
    assert_kind_of Net::HTTP::Get, call[:req]
  end

  test "a balance of -1 means the key was refused" do
    error = assert_raises(Contacts::ZeroBounce::Error) { client([ 200, { "Credits" => "-1" }.to_json ]).credits }
    assert_match "refused the API key", error.message
  end

  test "send_file posts one multipart CSV to the bulk host and returns the file id" do
    zb = client([ 200, { success: true, message: "File Accepted", file_id: "abc-123" }.to_json ])
    assert_equal "abc-123", zb.send_file([ "a@example.com", "b@example.com" ])

    call = @calls.first
    assert_equal "bulkapi.zerobounce.net", call[:uri].host
    assert_equal "/v2/sendfile", call[:uri].path
    assert_kind_of Net::HTTP::Post, call[:req]
    assert_match %r{\Amultipart/form-data; boundary=}, call[:req]["Content-Type"]
    body = call[:req].body
    assert_match %r{name="api_key"\r\n\r\n#{KEY}\r\n}, body
    assert_match %r{name="email_address_column"\r\n\r\n1\r\n}, body, "the column is 1-based"
    assert_match %r{name="has_header_row"\r\n\r\ntrue\r\n}, body
    assert_match %r{name="file"; filename="contacts-\d+\.csv"\r\nContent-Type: text/csv\r\n\r\nemail\na@example.com\nb@example.com\n}, body
  end

  test "send_file refuses an empty list without a request" do
    zb = client
    assert_raises(Contacts::ZeroBounce::Error) { zb.send_file([]) }
    assert_empty @calls
  end

  test "a success:false answer raises its message, with the key scrubbed" do
    zb = client([ 200, { success: false, error_message: "Invalid API key #{KEY}" }.to_json ])
    error = assert_raises(Contacts::ZeroBounce::Error) { zb.send_file([ "a@example.com" ]) }
    assert_match "Invalid API key [FILTERED]", error.message
    assert_no_match KEY, error.message
  end

  test "an HTTP error names the endpoint and never the query string" do
    zb = client([ 500, "oops" ])
    error = assert_raises(Contacts::ZeroBounce::Error) { zb.file_status("f1") }
    assert_equal "bulkapi.zerobounce.net/v2/filestatus answered HTTP 500", error.message
  end

  test "a network failure becomes an Error without the key" do
    zb = Contacts::ZeroBounce.new(api_key: KEY, transport: ->(_uri, _req) { raise Net::ReadTimeout })
    error = assert_raises(Contacts::ZeroBounce::Error) { zb.credits }
    assert_match "unreachable: Net::ReadTimeout", error.message
    assert_no_match KEY, error.message
  end

  test "file_status asks the bulk host for the file, and complete? reads it" do
    zb = client([ 200, { success: true, file_status: "Processing", complete_percentage: "40%" }.to_json ],
                [ 200, { success: true, file_status: "Complete" }.to_json ])
    first = zb.file_status("f1")
    assert_equal "/v2/filestatus", @calls.first[:uri].path
    assert_equal "f1", query(@calls.first)["file_id"]
    assert_not zb.complete?(first)
    assert zb.complete?(zb.file_status("f1"))
  end

  test "results parse the ZB status columns of the downloaded file" do
    file = <<~CSV
      "email","ZB Status","ZB Sub Status","ZB Account","ZB Domain"
      "A@Example.com","valid","","a","example.com"
      "b@example.com","invalid","mailbox_not_found","b","example.com"
      "c@example.com","catch-all","","c","example.com"
      "d@example.com","do_not_mail","role_based","d","example.com"
    CSV
    zb = client([ 200, file ])
    results = zb.results("f1")

    assert_equal "/v2/getfile", @calls.first[:uri].path
    assert_equal [ %w[a@example.com valid], %w[b@example.com invalid], %w[c@example.com catch-all], %w[d@example.com do_not_mail] ],
                 results.map { [ _1.email, _1.status ] }
    assert_equal [ nil, "mailbox_not_found", nil, "role_based" ], results.map(&:sub_status)
  end

  test "results tolerate header spelling and a byte-order mark" do
    zb = client
    results = zb.parse_results("\uFEFFEmail Address,zb_status,zb_sub_status\nx@example.com,Spamtrap,\n")
    assert_equal [ [ "x@example.com", "spamtrap", nil ] ], results.map { [ _1.email, _1.status, _1.sub_status ] }
  end

  # Regression, found by the 2026-09-29 one-address smoke: Net::HTTP hands the
  # file back as ASCII-8BIT, led by a UTF-8 byte-order mark, and a UTF-8 regexp
  # on that body raised Encoding::CompatibilityError. Header and row are the
  # real file's.
  test "results parse the real file: binary body, byte-order mark, ZB Sub status" do
    real = "\uFEFF\"email\",\"ZB Status\",\"ZB Sub status\",\"ZB Account\",\"ZB Domain\",\"ZB Domain Age Days\"\r\n" \
           "\"valid@example.com\",\"valid\",\"\",\"\",\"example.com\",\"9692\"\r\n"
    zb = client([ 200, real.b ])
    results = zb.results("f1")
    assert_equal [ [ "valid@example.com", "valid", nil ] ], results.map { [ _1.email, _1.status, _1.sub_status ] }
  end

  test "a results file with no status column raises rather than guessing" do
    error = assert_raises(Contacts::ZeroBounce::Error) { client.parse_results("email\nx@example.com\n") }
    assert_match "no status column", error.message
  end

  test "getfile answering JSON is an error, not a results file" do
    zb = client([ 200, { success: false, error_message: "File not found" }.to_json ])
    error = assert_raises(Contacts::ZeroBounce::Error) { zb.results("nope") }
    assert_match "File not found", error.message
  end
end
