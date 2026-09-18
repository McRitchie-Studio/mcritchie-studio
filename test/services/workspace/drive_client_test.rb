require "test_helper"

# [unit] Workspace::DriveClient — the query rule, paging, and the retry policy's
# one real decision: a throttle waits, a refusal does not.
class WorkspaceDriveClientTest < ActiveSupport::TestCase
  # Records what the gem's service object was asked for. Hand-rolled, like the
  # the Gmail lane's doubles, so nothing reaches Google.
  class ServiceDouble
    attr_reader :calls

    def initialize(pages: [], raises: nil)
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
      metadata
    end

    def update_file(id, metadata, **kwargs)
      @calls << [ :update_file, id, { name: metadata.name, has_body: !kwargs[:upload_source].nil? } ]
      metadata
    end

    def list_permissions(id, **kwargs)
      @calls << [ :list_permissions, id ]
      Struct.new(:permissions).new([])
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

  test "files_export returns the exported bytes" do
    service = ServiceDouble.new
    bytes = client(service).files_export("doc-id", mime_type: "application/pdf")

    assert_equal "exported-application/pdf", bytes
  end

  test "files_download returns the raw bytes" do
    assert_equal "bytes-for-bin-id", client(ServiceDouble.new).files_download("bin-id")
  end
end
