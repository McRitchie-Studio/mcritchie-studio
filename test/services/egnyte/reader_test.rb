require "test_helper"
require "support/egnyte_connect_fakes"

# [unit] Egnyte::Reader: the request shapes of Egnyte's Public API on a
# domain's own host: a folder page (list_content, count, offset), a file's
# metadata, the one upload (raw bytes with their SHA-512), whoami, per-segment
# path encoding, the page walk the bulk import will use, a 401's one refresh,
# and Egnyte's errors said plainly. Egnyte is a stand-in throughout.
class Egnyte::ReaderTest < ActiveSupport::TestCase
  include EgnyteConnectFakes

  NOW = Time.utc(2026, 11, 6, 18, 0, 0)
  API = "https://example.egnyte.com/pubapi/v1".freeze

  setup { @connection = store_egnyte(access_token: "a1", refresh_token: "r1", now: Time.current) }
  teardown { reset_egnyte_connect }

  def reader = Egnyte::Reader.new(@connection)

  test "[unit] a folder page lists subfolders and files with their details, on the domain's host with the stored token" do
    egnyte_reads([ :get, "/fs/Shared" ] => [ 200, SHARED ])
    with_egnyte_env { egnyte_tokens }
    page = reader.folder

    request = egnyte_read_requests.sole
    assert_equal "#{API}/fs/Shared?list_content=true&count=100&offset=0", request[:url]
    assert_equal [ :get, "a1" ], [ request[:method], request[:token] ]
    assert_empty egnyte_token_requests, "a fresh token spends no refresh"
    assert_equal [ "/Shared", 2, 1, 3 ], [ page.path, page.folders.size, page.files.size, page.total_count ]
    assert_not page.more?
    assert_equal %w[Projects Contracts], page.folders.map(&:name)
    assert page.folders.all?(&:folder?)
    file = page.files.sole
    assert_equal [ "Read me.txt", "/Shared/Read me.txt", 1023, "alex", 3, false ],
                 [ file.name, file.path, file.size, file.uploaded_by, file.num_versions, file.folder? ]
    assert_equal Time.utc(2026, 11, 3, 17, 0, 0), file.last_modified
    assert_equal Time.utc(2025, 11, 3, 17, 0, 0).to_i, page.folders.first.last_modified.to_i, "a folder's epoch milliseconds"
  end

  test "[unit] each path segment is encoded on its own and the slashes are kept; dot segments are refused" do
    assert_equal "/Shared/a%20b/c%3Fd/%24e.txt", Egnyte::Reader.encode_path("Shared/a b//c?d/$e.txt")
    [ "", "/", "/Shared/../Private", "./x" ].each do |path|
      assert_raises(ArgumentError, path) { Egnyte::Reader.encode_path(path) }
    end
  end

  test "[unit] metadata reads one file and says what Egnyte answered for a missing one" do
    egnyte_reads([ :get, "/fs/Shared/Read%20me.txt" ] => [ 200, SHARED[:files].first.merge(is_folder: false) ],
                 [ :get, "/fs/Shared/gone" ] => [ 404, { errorMessage: "File or folder does not exist" } ])
    file = reader.metadata("/Shared/Read me.txt")

    assert_equal [ "Read me.txt", 1023, "e-1", "g-1", "abc" ], [ file.name, file.size, file.entry_id, file.group_id, file.checksum ]
    error = assert_raises(Egnyte::OAuthClient::Error) { reader.metadata("/Shared/gone") }
    assert_equal "Egnyte answered 404: File or folder does not exist", error.message
  end

  test "[unit] a file named as a folder is refused" do
    egnyte_reads([ :get, "/fs/Shared/x.txt" ] => [ 200, { name: "x.txt", is_folder: false } ])

    assert_raises(Egnyte::OAuthClient::Error) { reader.folder("/Shared/x.txt") }
  end

  test "[unit] upload posts the raw bytes with their SHA-512 to fs-content and answers the stored file" do
    egnyte_reads([ :post, "/fs-content/" ] => [ 200, { checksum: "c", entry_id: "e-9", group_id: "g-9" } ])
    bytes = "hello, egnyte".b
    file = reader.upload("/Shared/Inbox/note 1.txt", StringIO.new(bytes), last_modified: NOW)

    request = egnyte_read_requests.sole
    assert_equal [ :post, "#{API}/fs-content/Shared/Inbox/note%201.txt", bytes ], [ request[:method], request[:url], request[:body] ]
    assert_equal({ "Content-Type" => "application/octet-stream", "X-Sha512-Checksum" => Digest::SHA512.hexdigest(bytes),
                   "Last-Modified" => "Fri, 06 Nov 2026 18:00:00 GMT" }, request[:headers])
    assert_equal [ "note 1.txt", "/Shared/Inbox/note 1.txt", bytes.bytesize, "e-9", "g-9" ],
                 [ file.name, file.path, file.size, file.entry_id, file.group_id ]
  end

  test "[unit] an upload over the simple limit is refused before anything is sent" do
    egnyte_reads({})
    big = Object.new.tap { |io| io.define_singleton_method(:read) { "x" * (Egnyte::Reader::SIMPLE_UPLOAD_LIMIT + 1) } }

    assert_raises(ArgumentError) { reader.upload("/Shared/big.bin", big) }
    assert_empty egnyte_read_requests
  end

  test "[unit] each_entry walks a folder page by page until Egnyte's total is reached" do
    page = ->(offset, names) { { path: "/Shared", is_folder: true, total_count: 3, offset:, folders: [], files: names.map { { name: _1, path: "/Shared/#{_1}" } } } }
    egnyte_reads([ :get, "/fs/Shared" ] => [ [ 200, page.(0, %w[a b]) ], [ 200, page.(2, %w[c]) ] ])

    assert_equal %w[a b c], reader.each_entry("/Shared", count: 2).map(&:name)
    assert_equal [ "#{API}/fs/Shared?list_content=true&count=2&offset=0", "#{API}/fs/Shared?list_content=true&count=2&offset=2" ],
                 egnyte_read_requests.map { _1[:url] }
  end

  test "[unit] a 401 refreshes the token once and retries with the new one" do
    with_egnyte_env do
      egnyte_tokens([ 200, egnyte_grant(access_token: "a2", refresh_token: "r2") ])
      egnyte_reads([ :get, "/fs/Shared" ] => [ [ 401, { message: "Not Authorized" } ], [ 200, SHARED ] ])

      assert_equal 3, reader.folder.total_count
      assert_equal %w[a1 a2], egnyte_read_requests.map { _1[:token] }
      assert_equal "r2", EgnyteConnection.find(@connection.id).refresh_token, "the rotated pair is stored"
    end
  end

  test "[unit] a 401 after the refresh is Revoked; a 429 says the rate limit" do
    with_egnyte_env do
      egnyte_tokens([ 200, egnyte_grant(access_token: "a2", refresh_token: "r2") ])
      egnyte_reads([ :get, "/fs/Shared" ] => [ 401, { message: "Not Authorized" } ], [ :get, "/whoami" ] => [ 429, {} ])

      assert_raises(Egnyte::OAuthClient::Revoked) { reader.folder }
      assert_equal 2, egnyte_read_requests.size, "one retry, not a loop"
      error = assert_raises(Egnyte::OAuthClient::RateLimited) { reader.whoami }
      assert_match(/2 calls a second/, error.message)
    end
  end

  test "[unit] whoami with a bare domain and token, as the callback reads it, spends no refresh" do
    egnyte_reads([ :get, "/whoami" ] => [ 200, WHOAMI ])
    with_egnyte_env { egnyte_tokens }

    assert_equal "alex", Egnyte::Reader.new(domain: "other", token: "fresh").whoami
    assert_equal [ "https://other.egnyte.com/pubapi/v1/whoami", "fresh" ], egnyte_read_requests.sole.values_at(:url, :token)
    assert_empty egnyte_token_requests
    assert_raises(ArgumentError) { Egnyte::Reader.new(domain: "other") }
  end
end
