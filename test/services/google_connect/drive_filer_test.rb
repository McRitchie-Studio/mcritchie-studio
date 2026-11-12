require "test_helper"
require "support/google_connect_fakes"
require "support/drive_filer_fake"

# [unit] GoogleConnect::DriveFiler (/tasks/drive-filing): folder paths made or
# reused, uploads (multipart and resumable), the md5 dedupe, dry runs that
# write nothing, the audit log (DriveFiling), Gmail attachments, and the
# refusals. A fake Drive records every call; no test here reaches Google.
# Every name and byte is invented.
class GoogleConnect::DriveFilerTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  TOKEN = "ya29.synthetic-drive-token".freeze
  PDF = "%PDF-1.4 invented fixture bytes\n".b.freeze
  MARK = { "mcritchieFiler" => "1" }.freeze

  setup do
    @connection = store_google(email: "owner@example.com", scope: "openid email #{DRIVE} #{GMAIL}", abilities: %i[drive gmail], user: users(:viewer))
  end

  teardown { GoogleConnect::DriveFiler.http = nil }

  def filer_with(drive, connection: @connection)
    GoogleConnect::DriveFiler.http = drive
    oauth = Struct.new(:token) { def access_token(_) = token }.new(TOKEN)
    GoogleConnect::DriveFiler.new(connection, requested_by: "pokemon", oauth:)
  end

  def folder(id, name, parent, marked: true)
    { "id" => id, "name" => name, "mimeType" => DriveFilerFake::FOLDER, "parents" => [ parent ], "appProperties" => (MARK if marked) }.compact
  end

  # --- folder paths ---------------------------------------------------------

  test "[unit] an applied mkdir makes each missing folder under the last, marked, and logs one row" do
    drive = DriveFilerFake.new
    result = filer_with(drive).mkdir("Records/Policies", apply: true)

    records, policies = drive.folders
    assert_equal [ "Records", [ "root" ], MARK ], records.values_at("name", "parents", "appProperties")
    assert_equal [ "Policies", [ records["id"] ], MARK ], policies.values_at("name", "parents", "appProperties")
    assert_equal [ "Records", "Records/Policies" ], result["created"]
    assert_equal policies["id"], result["folder_id"]
    row = DriveFiling.sole
    assert_equal [ "owner@example.com", "mkdir", "Records/Policies", policies["id"], true, "pokemon" ],
                 row.values_at(:mailbox, :action, :folder_path, :drive_file_id, :applied, :requested_by)
  end

  test "[unit] mkdir reuses a folder the hub made and makes only what is missing" do
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root") ])
    result = filer_with(drive).mkdir("Records/Policies", apply: true)

    assert_equal [ "Records/Policies" ], result["created"]
    assert_equal 1, drive.writes.size, "Records is reused, only Policies is made"
    assert_equal [ "f-records" ], drive.folders.last["parents"]
  end

  test "[unit] a same-named folder the hub did not make is never reused" do
    drive = DriveFilerFake.new(items: [ folder("theirs", "Records", "root", marked: false) ])
    filer_with(drive).mkdir("Records", apply: true)

    made = drive.folders.last
    assert_not_equal "theirs", made["id"]
    assert_equal MARK, made["appProperties"]
    assert drive.queries.all? { _1.include?("appProperties has { key='mcritchieFiler' and value='1' }") }, "every lookup asks for the mark"
  end

  test "[unit] a dry mkdir makes nothing, names what it would make and logs the run" do
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root") ])
    result = filer_with(drive).mkdir("Records/Policies/2026")

    assert_empty drive.writes
    assert_equal [ "Records/Policies", "Records/Policies/2026" ], result["would_create"]
    assert_nil result["folder_id"]
    assert_equal [ "mkdir", false ], DriveFiling.sole.values_at(:action, :applied)
  end

  test "[unit] a name with a quote is escaped in the query" do
    drive = DriveFilerFake.new
    filer_with(drive).mkdir("Bob's Records", apply: true)
    assert_includes drive.queries.first, "name = 'Bob\\'s Records'"
    assert_equal "Bob's Records", drive.folders.sole["name"]
  end

  test "[unit] a blank, too deep or dotted path is refused before any call" do
    filer = filer_with(drive = DriveFilerFake.new)
    [ "", " / ", "a/../b", (1..11).map(&:to_s).join("/"), "a/b\u0001c" ].each do |path|
      assert_raises(GoogleConnect::DriveFiler::Error, path.inspect) { filer.mkdir(path, apply: true) }
    end
    assert_empty drive.calls
  end

  # --- uploads --------------------------------------------------------------

  test "[unit] an applied upload makes the path and files the bytes as a marked multipart upload" do
    drive = DriveFilerFake.new
    filed = filer_with(drive).upload(name: "sample-policy.pdf", content: PDF, folder: "Records/Policies", apply: true)

    upload = drive.uploads.sole
    assert_includes upload[1], "uploadType=multipart"
    file = drive.items.last
    assert_equal [ "sample-policy.pdf", [ drive.folders.last["id"] ], MARK, Digest::MD5.hexdigest(PDF) ],
                 file.values_at("name", "parents", "appProperties", "md5Checksum")
    assert_equal [ file["id"], false, true, [ "Records", "Records/Policies" ] ], filed.to_h.values_at(:drive_file_id, :duplicate, :applied, :created_folders)
    assert_match %r{application/pdf}, upload[2].b[/Content-Type: (\S+)\r\n\r\n%PDF/, 1].to_s, "the type follows the file"

    row = DriveFiling.sole
    assert_equal [ "upload", "Records/Policies", "sample-policy.pdf", Digest::MD5.hexdigest(PDF), PDF.bytesize, "local", file["id"], true, false ],
                 row.values_at(:action, :folder_path, :file_name, :md5, :byte_size, :source, :drive_file_id, :applied, :duplicate)
  end

  test "[unit] a file over the multipart size takes a resumable session to Google's upload host" do
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root") ])
    big = "x".b * (GoogleConnect::DriveFiler::MULTIPART_MAX + 1)
    filed = filer_with(drive).upload(name: "scan.pdf", content: big, folder: "Records", apply: true)

    assert_equal [ :post, :put ], drive.uploads.map(&:first)
    assert_equal big.bytesize.to_s, drive.uploads.first[3]["X-Upload-Content-Length"]
    assert_equal Digest::MD5.hexdigest(big), drive.items.last["md5Checksum"]
    assert_equal drive.items.last["id"], filed.drive_file_id
  end

  test "[unit] an upload session outside Google's upload host is refused, with no bytes sent" do
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root") ])
    rogue = lambda do |method, url, token, body, headers|
      next [ 200, "", { "Location" => "https://evil.example/upload" } ] if url.include?("uploadType=resumable")

      drive.call(method, url, token, body, headers)
    end
    big = "x".b * (GoogleConnect::DriveFiler::MULTIPART_MAX + 1)
    assert_raises(GoogleConnect::OAuthClient::Error) { filer_with(rogue).upload(name: "scan.pdf", content: big, folder: "Records", apply: true) }
    assert_empty drive.calls.select { _1.first == :put }
  end

  test "[unit] a file whose md5 already sits in the folder is skipped, not uploaded again" do
    existing = { "id" => "f-old", "name" => "older-name.pdf", "parents" => [ "f-records" ], "appProperties" => MARK,
                 "md5Checksum" => Digest::MD5.hexdigest(PDF) }
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root"), existing ])
    filed = filer_with(drive).upload(name: "sample-policy.pdf", content: PDF, folder: "Records", apply: true)

    assert_empty drive.writes
    assert filed.duplicate
    assert_equal "f-old", filed.drive_file_id
    assert_equal [ true, true, "f-old" ], DriveFiling.sole.values_at(:applied, :duplicate, :drive_file_id)
  end

  test "[unit] a dry upload writes nothing to Drive and logs the run" do
    drive = DriveFilerFake.new
    filed = filer_with(drive).upload(name: "sample-policy.pdf", content: PDF, folder: "Records/Policies")

    assert_empty drive.writes, "a dry run makes no folder and uploads nothing"
    assert_not filed.applied
    assert_nil filed.drive_file_id
    assert_equal [ "Records", "Records/Policies" ], filed.created_folders
    assert_equal [ "upload", false, nil ], DriveFiling.sole.values_at(:action, :applied, :drive_file_id)
  end

  test "[unit] bytes whose md5 does not match the sender's are refused" do
    drive = DriveFilerFake.new
    assert_raises(GoogleConnect::DriveFiler::Error) do
      filer_with(drive).upload(name: "a.pdf", content: PDF, folder: "Records", apply: true, expected_md5: "0" * 32)
    end
    assert_empty drive.calls
    assert_equal 0, DriveFiling.count
  end

  test "[unit] an empty, oversized or unnamed file is refused before any call" do
    filer = filer_with(drive = DriveFilerFake.new)
    assert_raises(GoogleConnect::DriveFiler::Error) { filer.upload(name: "a.pdf", content: "", folder: "Records", apply: true) }
    assert_raises(GoogleConnect::DriveFiler::Error) { filer.upload(name: "", content: PDF, folder: "Records", apply: true) }
    huge = "x".b * (GoogleConnect::DriveFiler::MAX_BYTES + 1)
    assert_raises(GoogleConnect::DriveFiler::Error) { filer.upload(name: "a.pdf", content: huge, folder: "Records", apply: true) }
    assert_empty drive.calls
  end

  test "[unit] a path in the file name keeps only its base name" do
    drive = DriveFilerFake.new
    filed = filer_with(drive).upload(name: "../../tmp/sample.pdf", content: PDF, folder: "Records", apply: true)
    assert_equal "sample.pdf", filed.name
  end

  # --- Gmail attachments ----------------------------------------------------

  def message_with(*names)
    { "mimeType" => "multipart/mixed", "parts" => [ { "mimeType" => "text/plain", "filename" => "", "body" => { "size" => 4 } } ] +
      names.each_with_index.map { |name, i| { "mimeType" => "application/pdf", "filename" => name, "body" => { "attachmentId" => "att-#{i}" } } } }
  end

  test "[unit] file_attachment files the message's one attachment, read with the Gmail grant" do
    drive = DriveFilerFake.new(messages: { "msg-1" => message_with("sample-card.pdf") }, attachments: { "att-0" => PDF })
    filed = filer_with(drive).file_attachment(message_id: "msg-1", folder: "Records/Cards", apply: true)

    assert_equal [ "sample-card.pdf", Digest::MD5.hexdigest(PDF), "gmail" ], filed.to_h.values_at(:name, :md5, :source)
    assert_equal Digest::MD5.hexdigest(PDF), drive.items.last["md5Checksum"]
    assert_equal "gmail", DriveFiling.sole.source
  end

  test "[unit] a message with several attachments needs --name, and --as renames the file" do
    drive = DriveFilerFake.new(messages: { "msg-1" => message_with("a.pdf", "b.pdf") }, attachments: { "att-1" => PDF })
    filer = filer_with(drive)
    error = assert_raises(GoogleConnect::DriveFiler::Error) { filer.file_attachment(message_id: "msg-1", folder: "Records") }
    assert_match(/2 attachments; name one with --name \(a\.pdf, b\.pdf\)/, error.message)

    filed = filer.file_attachment(message_id: "msg-1", folder: "Records", name: "B.PDF", as: "renamed.pdf", apply: true)
    assert_equal "renamed.pdf", filed.name
  end

  test "[unit] file_attachment is refused without the Gmail grant" do
    drive_only = store_google(email: "driveonly@example.com", scope: "openid email #{DRIVE}", abilities: %i[drive], user: users(:viewer))
    drive = DriveFilerFake.new
    error = assert_raises(GoogleConnect::DriveFiler::Error) do
      filer_with(drive, connection: drive_only).file_attachment(message_id: "msg-1", folder: "Records", apply: true)
    end
    assert_match(/has not connected Gmail/, error.message)
    assert_empty drive.calls
  end

  # --- refusals and the never-list ------------------------------------------

  test "[unit] upload refuses a connection without the drive ability, and a legacy one" do
    gmail_only = store_google(email: "gmailonly@example.com", scope: "openid email #{GMAIL}", abilities: %i[gmail], user: users(:viewer))
    error = assert_raises(GoogleConnect::DriveFiler::Error) { GoogleConnect::DriveFiler.new(gmail_only, requested_by: "pokemon") }
    assert_match(/has not connected Google Drive/, error.message)

    legacy = store_google(email: "legacy@example.com", scope: "openid email #{DRIVE_LEGACY}", abilities: [], user: users(:viewer))
    legacy.update!(scope: "openid email #{DRIVE_LEGACY}")
    error = assert_raises(GoogleConnect::DriveFiler::Error) { GoogleConnect::DriveFiler.new(legacy, requested_by: "pokemon") }
    assert_match(/reconnect Drive/, error.message)

    assert_raises(GoogleConnect::DriveFiler::Error) { GoogleConnect::DriveFiler.new(@connection, requested_by: " ") }
  end

  test "[unit] no token in an error, the log or the answer" do
    drive = DriveFilerFake.new(fail_with: 401)
    error = assert_raises(GoogleConnect::OAuthClient::Error) { filer_with(drive).upload(name: "a.pdf", content: PDF, folder: "Records", apply: true) }

    assert_equal "Google Drive answered 401: Insufficient Permission", error.message
    assert_equal [ TOKEN ], drive.tokens.uniq, "the token goes to Google as the bearer"
    row = DriveFiling.sole
    assert_match(/Insufficient Permission/, row.error)
    assert_not_includes row.attributes.to_json, TOKEN
    assert_not_includes row.attributes.to_json, PDF.strip, "the log never holds the bytes"

    ok = DriveFilerFake.new
    filed = filer_with(ok).upload(name: "a.pdf", content: PDF, folder: "Records", apply: true)
    assert_not_includes filed.to_h.to_json, TOKEN
    assert_not_includes filed.to_h.to_json, PDF.strip
  end

  test "[unit] it only ever GETs, POSTs to create, and PUTs to its own upload session; never deletes or shares" do
    drive = DriveFilerFake.new(messages: { "msg-1" => message_with("c.pdf") }, attachments: { "att-0" => PDF })
    filer = filer_with(drive)
    filer.mkdir("Records/Policies", apply: true)
    filer.upload(name: "a.pdf", content: PDF, folder: "Records/Policies", apply: true)
    filer.upload(name: "b.pdf", content: "y".b * (GoogleConnect::DriveFiler::MULTIPART_MAX + 1), folder: "Records", apply: true)
    filer.file_attachment(message_id: "msg-1", folder: "Records", apply: true)

    assert_equal %i[get post put], drive.calls.map(&:first).uniq.sort
    assert drive.calls.none? { URI(_1[1]).path.match?(/permissions|trash|copy|delete/i) }, "no call reaches a share, trash, copy or delete endpoint"

    %w[app/services/google_connect/drive_filer.rb app/services/drive_export.rb bin/lib/drive_cli.rb bin/drive].each do |path|
      code = Rails.root.join(path).read.lines.reject { _1.lstrip.start_with?("#") }.join
      assert_no_match(/Net::HTTP::(?:Delete|Patch)|:delete\b|:patch\b|permissions|"trashed"\s*=>\s*true|trashed:\s*true|addParents|removeParents|files_(?:trash|delete)/,
                      code, "#{path} never deletes, trashes, shares or moves a file")
    end
    assert_raises(ArgumentError) { filer.send(:call, :delete, "#{GoogleConnect::DriveFiler::FILES_URL}/f-1") }
    assert_raises(ArgumentError) { filer.send(:call, :get, "https://example.com/") }
  end

  test "[unit] list names only what the hub made in a folder" do
    drive = DriveFilerFake.new(items: [ folder("f-records", "Records", "root"), folder("theirs", "Theirs", "root", marked: false),
                                        { "id" => "f-1", "name" => "x.pdf", "parents" => [ "f-records" ], "appProperties" => MARK } ])
    filer = filer_with(drive)
    assert_equal [ "Records" ], filer.list.map { _1["name"] }
    assert_equal [ "x.pdf" ], filer.list("Records").map { _1["name"] }
    assert_empty filer.list("Missing")
  end
end
