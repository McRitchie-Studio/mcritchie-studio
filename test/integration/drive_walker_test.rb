require "test_helper"
require "google/apis/drive_v3"

# [integration] Workspace::DriveWalker across its boundaries: a Drive tree
# (stubbed) in, SourceDocument rows in the real database out.
#
# The files are REAL Google::Apis::DriveV3::File objects, not hand-rolled
# doubles. A double answers any attribute name it is asked, so a walker that
# read `file.web_link` instead of `file.web_view_link` would pass every test and
# record nil in production. Using the gem's own class makes a wrong name fail.
class DriveWalkerTest < ActionDispatch::IntegrationTest
  Drive = Google::Apis::DriveV3

  # A folder tree: { folder_id => [files] }. Answers exactly what the walker
  # asks for, records every query, and can be told to fail on one folder.
  # It implements ONLY `paged` — the walker has no way to download a document.
  class TreeClient
    attr_reader :queries

    def initialize(tree, fail_on: nil)
      @tree = tree
      @fail_on = fail_on
      @queries = []
    end

    def paged(query:)
      @queries << query
      folder = query[/'([^']+)' in parents/, 1] or raise "unexpected query: #{query}"
      raise Google::Apis::ServerError, "backendError on #{folder}" if folder == @fail_on

      @tree.fetch(folder, [])
    end
  end

  def file(id, name, version:, mime: "application/pdf", owner: "owner@example.test", parents: [ "root" ], **extra)
    Drive::File.new(
      id: id, name: name, mime_type: mime, version: version,
      modified_time: DateTime.new(2026, 9, 1), size: 1024, md5_checksum: "md5-#{id}",
      web_view_link: "https://drive.example.test/#{id}", parents: parents,
      owners: [ Drive::User.new(email_address: owner) ],
      capabilities: Drive::File::Capabilities.new(can_edit: false),
      **extra
    )
  end

  def folder(id, name) = Drive::File.new(id: id, name: name, mime_type: Workspace::DriveWalker::FOLDER_MIME)

  setup do
    @account = WorkspaceAccount.create!(domain: "synthetic.test", entity: "synthetic-entity")
    @account.mark_verified!
    @source = KnowledgeSource.create!(kind: "google_drive", name: "Synthetic deal folder",
                                      external_root_id: "root", entity: "synthetic-entity",
                                      access: { "samson" => "full" }, workspace_account: @account)
  end

  def walk(tree, **opts)
    Workspace::DriveWalker.new(client: TreeClient.new(tree, **opts)).call(@source)
  end

  def base_tree
    {
      "root" => [ file("doc-a", "Agreement.pdf", version: 3), folder("sub", "Schedules") ],
      "sub" => [ file("doc-b", "Schedule A.pdf", version: 1, parents: [ "sub" ]) ]
    }
  end

  test "a first walk records every document, recursing folders, as metadata" do
    r = walk(base_tree)

    assert r.ok?, r.error
    assert_equal 2, r.added
    assert_equal %w[doc-a doc-b], @source.source_documents.order(:external_id).pluck(:external_id)

    a = @source.source_documents.find_by!(external_id: "doc-a")
    assert_equal "Agreement.pdf", a.title
    assert_equal "3", a.remote_version
    assert_equal "https://drive.example.test/doc-a", a.web_url
    assert_equal "owner@example.test", a.owner_email
    assert_equal "md5-doc-a", a.checksum
    assert_equal false, a.metadata["can_edit"]
    assert a.needs_indexing?, "a newly found document has never been indexed"
  end

  test "folders are walked, not recorded as documents" do
    walk(base_tree)
    refute @source.source_documents.exists?(external_id: "sub")
  end

  test "new documents inherit the source's entity and access" do
    walk(base_tree)
    doc = @source.source_documents.find_by!(external_id: "doc-a")

    assert_equal "synthetic-entity", doc.entity
    assert_equal({ "samson" => "full" }, doc.access)
  end

  test "a second walk of an unchanged tree changes nothing" do
    walk(base_tree)

    assert_no_difference -> { SourceDocument.count } do
      r = walk(base_tree)
      assert_equal 0, r.added
      assert_equal 0, r.changed
      assert_equal 2, r.unchanged
    end
  end

  test "a version change is reported, and makes an indexed document stale" do
    walk(base_tree)
    @source.source_documents.find_by!(external_id: "doc-a").mark_indexed!

    tree = base_tree
    tree["root"][0] = file("doc-a", "Agreement.pdf", version: 4)
    r = walk(tree)

    assert_equal 1, r.changed
    assert @source.source_documents.find_by!(external_id: "doc-a").needs_indexing?
  end

  test "a COMPLETE walk marks a document it no longer sees as missing — never deletes it" do
    walk(base_tree)

    tree = base_tree
    tree["sub"] = []
    r = walk(tree)

    assert r.ok?
    assert_equal 1, r.missing
    gone = @source.source_documents.find_by!(external_id: "doc-b")
    assert_equal "missing", gone.status
  end

  test "a FAILED walk marks NOTHING missing and records the failure" do
    # THE correctness property. Page one of the tree is read, the subfolder
    # fails; the documents under it were never reached, so "I did not see them"
    # proves nothing about them.
    walk(base_tree)
    walked_at = @source.reload.last_walked_at

    r = walk(base_tree, fail_on: "sub")

    refute r.ok?
    assert_match(/backendError/, r.error)
    assert_equal 0, r.missing
    assert_equal "active", @source.source_documents.find_by!(external_id: "doc-b").status,
      "a document the failed walk never reached must stay active"
    assert_match(/backendError/, @source.reload.last_walk_error)
    assert_equal walked_at, @source.last_walked_at, "last_walked_at means the last walk that COMPLETED"
  end

  test "a successful walk clears the previous walk's error" do
    walk(base_tree, fail_on: "sub")
    assert @source.reload.last_walk_error

    walk(base_tree)
    assert_nil @source.reload.last_walk_error
  end

  test "a re-walk never overwrites triage, but does refresh the remote metadata" do
    walk(base_tree)
    doc = @source.source_documents.find_by!(external_id: "doc-a")
    doc.update!(access: { "samson" => "aware" }, entity: "reclassified", tags: [ "reviewed" ])

    tree = base_tree
    tree["root"][0] = file("doc-a", "Agreement (signed).pdf", version: 5)
    walk(tree)
    doc.reload

    assert_equal({ "samson" => "aware" }, doc.access)
    assert_equal "reclassified", doc.entity
    assert_equal [ "reviewed" ], doc.tags
    assert_equal "Agreement (signed).pdf", doc.title, "remote fields DO refresh"
    assert_equal "5", doc.remote_version
  end

  test "a missing document that comes back is active again, triage intact" do
    walk(base_tree)
    @source.source_documents.find_by!(external_id: "doc-b").update!(tags: [ "keep" ])
    walk(base_tree.merge("sub" => []))
    assert_equal "missing", @source.source_documents.find_by!(external_id: "doc-b").status

    walk(base_tree)
    back = @source.source_documents.find_by!(external_id: "doc-b")
    assert_equal "active", back.status
    assert_equal [ "keep" ], back.tags
  end

  test "a folder reachable twice is walked once, so a cycle terminates" do
    tree = {
      "root" => [ folder("a", "A"), file("doc-a", "x.pdf", version: 1) ],
      "a" => [ folder("root", "back to root"), folder("a", "self") ]
    }
    client = TreeClient.new(tree)
    r = Workspace::DriveWalker.new(client: client).call(@source)

    assert r.ok?, r.error
    assert_equal 1, client.queries.count { |q| q.include?("'a' in parents") }
    assert_equal 1, client.queries.count { |q| q.include?("'root' in parents") }
  end

  test "a shortcut is recorded with its target and never followed" do
    shortcut = file("sc-1", "Shortcut to elsewhere", version: 1,
                    mime: Workspace::DriveWalker::SHORTCUT_MIME,
                    shortcut_details: Drive::File::ShortcutDetails.new(
                      target_id: "outside-folder", target_mime_type: Workspace::DriveWalker::FOLDER_MIME))
    client = TreeClient.new({ "root" => [ shortcut ], "outside-folder" => [ file("x", "x", version: 1) ] })
    Workspace::DriveWalker.new(client: client).call(@source)

    sc = @source.source_documents.find_by!(external_id: "sc-1")
    assert_equal "outside-folder", sc.metadata["shortcut_target_id"]
    refute(client.queries.any? { |q| q.include?("outside-folder") },
           "following a shortcut could walk out of the folder the operator chose")
  end

  test "the walker only lists — it has no way to download a document" do
    # The no-duplication rule, enforced by what the walker can call: its client
    # implements `paged` and nothing else, and the walk still succeeds.
    assert_equal [ :paged ], TreeClient.public_instance_methods(false) - [ :queries ]
    assert walk(base_tree).ok?
  end

  test "a non-Drive source is a programming error, and raises" do
    egnyte = KnowledgeSource.create!(kind: "egnyte", name: "e", external_root_id: "e-root")
    assert_raises(ArgumentError) { Workspace::DriveWalker.new(client: TreeClient.new({})).call(egnyte) }
  end

  test "a source with NO workspace refuses to walk — it never falls back to a global identity" do
    # Falling back is how a walk ends up reading the wrong company's Drive.
    orphan = KnowledgeSource.create!(kind: "google_drive", name: "Unattached",
                                     external_root_id: "orphan-root")
    client = TreeClient.new(base_tree)

    error = assert_raises(ArgumentError) { Workspace::DriveWalker.new(client: client).call(orphan) }
    assert_match(/no workspace_account/, error.message)
    assert_empty client.queries, "nothing may be read before we know whose Drive it is"
  end

  test "a source whose workspace is not yet proven refuses to walk" do
    @account.update!(status: "pending")
    client = TreeClient.new(base_tree)

    error = assert_raises(ArgumentError) { Workspace::DriveWalker.new(client: client).call(@source) }
    assert_match(/pending, not active/, error.message)
    assert_empty client.queries
  end

  test "the walk runs as its own workspace's subject" do
    # The subject is resolved from the source's workspace, never from a global
    # default — which is what makes two clients safe to index side by side.
    seen = []
    walker = Workspace::DriveWalker.new(client: TreeClient.new(base_tree))
    walker.define_singleton_method(:client) do
      seen << instance_variable_get(:@subject)
      instance_variable_get(:@client)
    end
    walker.call(@source)

    assert_equal [ "team@synthetic.test" ], seen.uniq
  end

  test "a REUSED walker builds a client per SUBJECT, never carrying the first source's identity" do
    # Deliberately does NOT inject a client, because the injection seam bypasses
    # the memo this guards. @subject is assigned per call while the built client
    # was memoized flat, so one walker instance walking two workspaces would
    # have read the second company's folder as the first company's user.
    other = WorkspaceAccount.create!(domain: "other.test", entity: "other-entity")
    other.mark_verified!
    other_source = KnowledgeSource.create!(kind: "google_drive", name: "Other folder",
                                           external_root_id: "other-root", entity: "other-entity",
                                           access: {}, workspace_account: other)
    tree = base_tree.merge("other-root" => [ file("doc-c", "Other.pdf", version: 1, parents: [ "other-root" ]) ])
    built = []
    walker = Workspace::DriveWalker.new

    Workspace::DriveClient.stub(:new, ->(subject:) { built << subject; TreeClient.new(tree) }) do
      walker.call(@source)
      walker.call(other_source)
    end

    assert_equal [ "team@synthetic.test", "team@other.test" ], built,
      "the second walk must open a client as its OWN workspace subject"
  end
end
