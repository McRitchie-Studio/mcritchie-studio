require "test_helper"

# [unit] SourceDocument — the freshness rule is the whole point of the index,
# so its edges are pinned here: never indexed, same version, moved version, a
# layer with no version, and a change that lands mid-index.
class SourceDocumentTest < ActiveSupport::TestCase
  setup do
    @source = KnowledgeSource.create!(kind: "google_drive", name: "Synthetic folder",
                                      external_root_id: "root-1")
  end

  def doc(**attrs)
    @source.source_documents.create!({ external_id: "f-#{SecureRandom.hex(3)}" }.merge(attrs))
  end

  test "a never-indexed document needs indexing" do
    assert doc(remote_version: "7").needs_indexing?
  end

  test "an indexed document at the same version does not" do
    d = doc(remote_version: "7")
    d.mark_indexed!

    refute d.needs_indexing?
    assert_equal "7", d.indexed_version
  end

  test "a version change makes it need indexing again" do
    d = doc(remote_version: "7")
    d.mark_indexed!
    d.update!(remote_version: "8")

    assert d.needs_indexing?
  end

  test "the rule compares VERSION, not timestamps" do
    # An older-looking timestamp must not hide a real change: Drive's version is
    # strictly increasing, while modifiedTime can lag or tie at one-second grain.
    d = doc(remote_version: "7", remote_modified_at: 1.day.ago)
    d.mark_indexed!(at: Time.current)
    d.update!(remote_version: "8", remote_modified_at: 2.days.ago)

    assert d.needs_indexing?, "a moved version outranks a stale-looking timestamp"
  end

  test "a layer that offers no version falls back to the timestamp" do
    d = doc(remote_version: nil, remote_modified_at: 3.days.ago)
    d.mark_indexed!(version: nil, at: 2.days.ago)
    refute d.needs_indexing?

    d.update!(remote_modified_at: 1.day.ago)
    assert d.needs_indexing?
  end

  test "mark_indexed! records WHICH version it acted on" do
    # The indexer read version 7; the document moved to 8 while it worked. The
    # index must still see 8 as new, so the indexer passes the version it read.
    d = doc(remote_version: "7")
    d.update!(remote_version: "8")
    d.mark_indexed!(version: "7")

    assert d.needs_indexing?
  end

  test "status is constrained, and the scopes split on it" do
    active = doc(status: "active")
    missing = doc(status: "missing")

    assert_raises(ActiveRecord::RecordInvalid) { doc(status: "deleted") }
    assert_includes SourceDocument.active, active
    assert_includes SourceDocument.missing, missing
  end

  test "external_id is unique within a source, not across sources" do
    doc(external_id: "same")
    assert_raises(ActiveRecord::RecordInvalid) { doc(external_id: "same") }

    other = KnowledgeSource.create!(kind: "google_drive", name: "Other", external_root_id: "root-2")
    assert other.source_documents.create!(external_id: "same")
  end

  test "there is no content column — the index holds metadata only" do
    # The operator's no-duplication rule, made structural: nothing in this table
    # can hold a document's bytes or text.
    content_like = SourceDocument.column_names.grep(/\A(body|content|text|bytes|data|blob|raw)\z/)
    assert_empty content_like, "a content column would make the index a copy of the layer"
  end
end
