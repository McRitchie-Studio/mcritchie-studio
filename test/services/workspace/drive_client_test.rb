require "test_helper"

# [unit] Workspace::DriveClient — the query rule, paging, and the retry policy's
# one real decision: a throttle waits, a refusal does not.
class WorkspaceDriveClientTest < ActiveSupport::TestCase
  # Records what the gem's service object was asked for. Hand-rolled, like the
  # the Gmail lane's doubles, so nothing reaches Google.
  class ServiceDouble
    attr_reader :calls

    def initialize(pages: [], raises: nil, permissions: [])
      @permissions = permissions
      @pages = pages
      @raises = Array(raises)
      @calls = []
    end

    def authorization=(_value); end

    def list_files(**kwargs)
      @calls << [ :list_files, kwargs ]
      raise @raises.shift if @raises.any?

      @pages.shift || page(files: [])
    end

    def get_file(id, **kwargs)
      @calls << [ :get_file, id, kwargs ]
      kwargs[:download_dest]&.write("bytes-for-#{id}")
      Struct.new(:id, :name, :head_revision_id, keyword_init: true).new(id: id, name: "n", head_revision_id: "r1")
    end

    def export_file(id, mime_type, **kwargs)
      @calls << [ :export_file, id, mime_type ]
      kwargs[:download_dest]&.write("exported-#{mime_type}")
      nil
    end

    def copy_file(id, metadata, **kwargs)
      @calls << [ :copy_file, id, { name: metadata.name, parents: metadata.parents } ]
      raise @raises.shift if @raises.any?

      metadata
    end

    def update_file(id, metadata, **kwargs)
      @calls << [ :update_file, id, { name: metadata.name, trashed: metadata.trashed, has_body: !kwargs[:upload_source].nil? } ]
      metadata
    end

    def create_file(metadata, **kwargs)
      @calls << [ :create_file, { name: metadata.name, parents: metadata.parents, mime_type: metadata.mime_type,
                                  content_type: kwargs[:content_type], has_body: !kwargs[:upload_source].nil? } ]
      raise @raises.shift if @raises.any?

      metadata
    end

    def create_permission(id, permission, **kwargs)
      @calls << [ :create_permission, id, { type: permission.type, role: permission.role, domain: permission.domain,
                                            discoverable: permission.allow_file_discovery,
                                            email: permission.email_address }.compact ]
      raise @raises.shift if @raises.any?

      permission
    end

    def list_permissions(id, **kwargs)
      @calls << [ :list_permissions, id ]
      Struct.new(:permissions).new(@permissions)
    end

    def self.page(files:, next_page_token: nil)
      Struct.new(:files, :next_page_token, keyword_init: true)
            .new(files: files, next_page_token: next_page_token)
    end

    def page(files:, next_page_token: nil) = self.class.page(files: files, next_page_token: next_page_token)
  end

  def throttled(retry_after: nil)
    Google::Apis::RateLimitError.new(
      "rateLimitExceeded", status_code: 429,
      header: (retry_after ? { "Retry-After" => retry_after.to_s } : {})
    )
  end

  def client(service, sleeps: [])
    Workspace::DriveClient.new(service: service, sleeper: ->(s) { sleeps << s })
  end

  test "files_list refuses a blank query rather than walking the whole Drive" do
    service = ServiceDouble.new
    subject = client(service)

    [ nil, "", "   " ].each do |blank|
      assert_raises(Workspace::ApiRetry::Error) { subject.files_list(query: blank) }
    end
    assert_empty service.calls, "a blank query must not reach Google at all"
  end

  test "files_list passes the query, cursor and page size through" do
    service = ServiceDouble.new(pages: [ ServiceDouble.page(files: [ 1 ]) ])
    client(service).files_list(query: "'folder-id' in parents", cursor: "c1", limit: 42)

    _name, kwargs = service.calls.first
    assert_equal "'folder-id' in parents", kwargs[:q]
    assert_equal "c1", kwargs[:page_token]
    assert_equal 42, kwargs[:page_size]
    assert kwargs[:supports_all_drives], "shared-drive files are the whole use case"
  end

  test "the requested fields carry the owner — the ownership guardrail's input" do
    # A caller cannot decide "do we own this?" without it, and a second
    # round-trip per file to find out is how that check gets skipped.
    assert_includes Workspace::DriveClient::FILE_FIELDS, "owners(emailAddress)"
    assert_includes Workspace::DriveClient::FILE_FIELDS, "capabilities(canEdit)"
    assert_includes Workspace::DriveClient::FILE_FIELDS, "headRevisionId"
    assert_includes Workspace::DriveClient::LIST_FIELDS, "nextPageToken"
  end

  test "paged walks every page and stops on an absent or blank token" do
    service = ServiceDouble.new(pages: [
      ServiceDouble.page(files: %w[a], next_page_token: "p2"),
      ServiceDouble.page(files: %w[b], next_page_token: "")
    ])

    assert_equal %w[a b], client(service).paged(query: "trashed = false"),
      "a blank next_page_token means done — treating it as a page loops forever"
  end

  test "a throttle waits the number Google asked for, then gives up" do
    service = ServiceDouble.new(raises: Array.new(8) { throttled(retry_after: 7) })
    sleeps = []

    assert_raises(Workspace::ApiRetry::Error) { client(service, sleeps: sleeps).files_list(query: "x") }
    assert_equal Array.new(Workspace::ApiRetry::MAX_RETRIES, 7), sleeps,
      "Retry-After is honoured, and MAX_RETRIES bounds the loop"
  end

  test "a throttle with no Retry-After backs off exponentially" do
    service = ServiceDouble.new(raises: Array.new(8) { throttled })
    sleeps = []

    assert_raises(Workspace::ApiRetry::Error) { client(service, sleeps: sleeps).files_list(query: "x") }
    assert_equal [ 1, 2, 4, 8, 16 ], sleeps
  end

  test "a permission refusal does NOT retry — on this codebase a 403 is often the guardrail" do
    refusal = Google::Apis::ClientError.new("insufficientFilePermissions", status_code: 403)
    service = ServiceDouble.new(raises: [ refusal ])
    sleeps = []

    assert_raises(Google::Apis::ClientError) { client(service, sleeps: sleeps).files_list(query: "x") }
    assert_empty sleeps, "retrying a refusal is just a slower refusal"
    assert_equal 1, service.calls.size
  end

  test "files_copy carries the name and the destination parent" do
    service = ServiceDouble.new
    client(service).files_copy("src-id", name: "Working copy", parents: [ "our-folder" ])

    _name, id, args = service.calls.first
    assert_equal "src-id", id
    assert_equal "Working copy", args[:name]
    assert_equal [ "our-folder" ], args[:parents],
      "a copy with no parent lands in the subject's root; into a folder we do not own it is refused"
  end

  test "files_create converts on upload: the stored type and the sent type travel separately" do
    service = ServiceDouble.new
    client(service).files_create(name: "Guide", parents: "kit", mime_type: "application/vnd.google-apps.document",
                                 body: "<h1>x</h1>", content_type: "text/html")

    _name, args = service.calls.first
    assert_equal [ "kit" ], args[:parents]
    assert_equal "application/vnd.google-apps.document", args[:mime_type]
    assert_equal "text/html", args[:content_type]
    assert args[:has_body]
  end

  FOLDER = Workspace::DriveClient::FOLDER_MIME

  def house_client(service, folder_user: "owner@mason.test")
    WorkspaceAccount.create!(domain: "mason.test", folder_user_email: folder_user)
    Workspace::DriveClient.new(subject: "team@mason.test", service: service, sleeper: ->(_) { })
  end

  def shares(service) = service.calls.select { |name, *| name == :create_permission }

  test "a new folder is shared with its Workspace's folder user as Editor" do
    service = ServiceDouble.new
    house_client(service).files_create(name: "Records", parents: "root", mime_type: FOLDER)

    assert_equal 1, shares(service).size
    args = shares(service).first.last
    assert_equal "owner@mason.test", args[:email]
    assert_equal "writer", args[:role]
  end

  test "a folder that inherits the user's access is not shared again" do
    inherited = Struct.new(:email_address, :type, :domain, :role, keyword_init: true).new(email_address: "Owner@mason.test", type: "user", role: "writer")
    service = ServiceDouble.new(permissions: [ inherited ])
    house_client(service).files_create(name: "Sub", parents: "records", mime_type: FOLDER)

    assert_empty shares(service)
  end

  test "a folder that inherits access through the user's domain is not shared again" do
    inherited = Struct.new(:email_address, :type, :domain, :role, keyword_init: true).new(type: "domain", domain: "mason.test", role: "writer")
    service = ServiceDouble.new(permissions: [ inherited ])
    house_client(service).files_create(name: "Sub", parents: "kit", mime_type: FOLDER)

    assert_empty shares(service)
  end

  test "a folder the user can only read is still shared as Editor" do
    inherited = Struct.new(:email_address, :type, :domain, :role, keyword_init: true).new(email_address: "owner@mason.test", type: "user", role: "reader")
    service = ServiceDouble.new(permissions: [ inherited ])
    house_client(service).files_create(name: "Sub", parents: "records", mime_type: FOLDER)

    assert_equal "writer", shares(service).first.last[:role]
  end

  test "a share that fails for a reason Google did not raise logs it and still returns the folder" do
    service = ServiceDouble.new
    client = house_client(service)
    service.define_singleton_method(:create_permission) { |*, **| raise "token refused" }
    folder = nil
    err = nil
    assert_difference -> { ErrorLog.count }, 1 do
      _out, err = capture_io { folder = client.files_create(name: "Records", parents: "root", mime_type: FOLDER) }
    end

    assert_equal "Records", folder.name
    assert_match(/created but not shared/, err)
    assert_match(/drive folder share/, ErrorLog.order(:id).last.target_name)
  end

  test "a share that fails warns and still returns the folder that landed" do
    service = ServiceDouble.new
    client = house_client(service)
    service.define_singleton_method(:create_permission) { |*, **| raise Google::Apis::ClientError.new("forbidden", status_code: 403) }
    folder = nil
    _out, err = capture_io { folder = client.files_create(name: "Records", parents: "root", mime_type: FOLDER) }

    assert_equal "Records", folder.name
    assert_match(/created but not shared/, err)
  end

  test "a Workspace with no folder user still creates the folder, and warns" do
    service = ServiceDouble.new
    _out, err = capture_io { house_client(service, folder_user: nil).files_create(name: "Records", parents: "root", mime_type: FOLDER) }

    assert_equal :create_file, service.calls.first.first
    assert_empty shares(service)
    assert_match(/not shared/, err)
  end

  test "shortcut_create sends the shortcut type, the destination and the target, and shares nothing" do
    service = ServiceDouble.new
    sent = nil
    original = service.method(:create_file)
    service.define_singleton_method(:create_file) { |metadata, **kwargs| sent = metadata; original.call(metadata, **kwargs) }
    house_client(service).shortcut_create(name: "Agreements", parent: "lender-folder", target_id: "master")

    assert_equal "application/vnd.google-apps.shortcut", sent.mime_type
    assert_equal [ "lender-folder" ], sent.parents
    assert_equal "master", sent.shortcut_details.target_id
    assert_empty shares(service)
  end

  test "a shortcut that may have landed is not retried" do
    service = ServiceDouble.new(raises: [ Google::Apis::ServerError.new("backendError", status_code: 500) ])
    assert_raises(Workspace::ApiRetry::Error, Google::Apis::ServerError) do
      house_client(service).shortcut_create(name: "Agreements", parent: "lender-folder", target_id: "master")
    end
    assert_equal 1, service.calls.count { |call| call.first == :create_file }
  end

  test "a file that is not a folder is not shared" do
    service = ServiceDouble.new
    house_client(service).files_create(name: "Doc", parents: "records", mime_type: "application/vnd.google-apps.document",
                                       body: "<p>x</p>", content_type: "text/html")

    assert_empty shares(service)
  end

  test "a create retries a throttle but never a server error, which may have landed" do
    sleeps = []
    service = ServiceDouble.new(raises: [ throttled, Google::Apis::ServerError.new("backendError", status_code: 503) ])

    error = assert_raises(Workspace::ApiRetry::Error) { client(service, sleeps: sleeps).files_create(name: "f", parents: [ "p" ]) }
    assert_match(/not retried/, error.message)
    assert_equal [ 1 ], sleeps, "the throttle waited once; the 503 did not retry"
    assert_equal 2, service.calls.size
  end

  test "files_export returns the exported bytes" do
    service = ServiceDouble.new
    bytes = client(service).files_export("doc-id", mime_type: "application/pdf")

    assert_equal "exported-application/pdf", bytes
  end

  test "files_download returns the raw bytes" do
    assert_equal "bytes-for-bin-id", client(ServiceDouble.new).files_download("bin-id")
  end

  test "a copy is not retried on a server error: a second copy would be a duplicate" do
    service = ServiceDouble.new(raises: [ Google::Apis::ServerError.new("backendError", status_code: 503) ])

    assert_raises(Workspace::ApiRetry::Error) { client(service).files_copy("src-id", name: "Doc", parents: [ "kit" ]) }
    assert_equal 1, service.calls.size
  end

  test "files_trash trashes rather than deletes, and sends no body" do
    service = ServiceDouble.new
    client(service).files_trash("draft-id")

    assert_equal [ [ :update_file, "draft-id", { name: nil, trashed: true, has_body: false } ] ], service.calls
  end

  test "permissions_create_domain grants the whole domain, findable in its Drive" do
    service = ServiceDouble.new
    client(service).permissions_create_domain("root-id", domain: "example.com")

    assert_equal [ [ :create_permission, "root-id", { type: "domain", role: "writer", domain: "example.com", discoverable: true } ] ],
                 service.calls
  end

  test "a domain grant is not retried on a server error, which may have landed" do
    service = ServiceDouble.new(raises: [ Google::Apis::ServerError.new("backendError", status_code: 503) ])

    assert_raises(Workspace::ApiRetry::Error) { client(service).permissions_create_domain("root-id", domain: "example.com") }
    assert_equal 1, service.calls.size
  end
end
