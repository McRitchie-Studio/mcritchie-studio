require "test_helper"

# [unit] KnowledgeSource — a layer instance: its kind, its identity, its default
# access, and the stale-document query the app reads.
class KnowledgeSourceTest < ActiveSupport::TestCase
  test "kind is one of the known layers" do
    assert KnowledgeSource.new(kind: "google_drive", name: "a", external_root_id: "r").valid?
    %w[egnyte transcripts].each do |kind|
      assert KnowledgeSource.new(kind: kind, name: "a", external_root_id: "r-#{kind}").valid?, kind
    end
    refute KnowledgeSource.new(kind: "dropbox", name: "a", external_root_id: "r").valid?
  end

  test "the same root cannot be registered twice for one kind" do
    KnowledgeSource.create!(kind: "google_drive", name: "a", external_root_id: "dup")
    refute KnowledgeSource.new(kind: "google_drive", name: "b", external_root_id: "dup").valid?
    assert KnowledgeSource.new(kind: "egnyte", name: "b", external_root_id: "dup").valid?
  end

  test "access uses the knowledge layer's own levels" do
    assert KnowledgeSource.new(kind: "google_drive", name: "a", external_root_id: "x",
                               access: { "samson" => "full" }).valid?
    refute KnowledgeSource.new(kind: "google_drive", name: "a", external_root_id: "y",
                               access: { "samson" => "admin" }).valid?
  end

  test "access defaults to none for every agent" do
    # The safe default: a new layer is invisible to agents until someone grants it.
    assert_equal({}, KnowledgeSource.create!(kind: "google_drive", name: "a", external_root_id: "z").access)
  end

  test "stale_documents lists active documents that need indexing, and nothing else" do
    source = KnowledgeSource.create!(kind: "google_drive", name: "a", external_root_id: "s")
    fresh = source.source_documents.create!(external_id: "fresh", remote_version: "1")
    fresh.mark_indexed!
    stale = source.source_documents.create!(external_id: "stale", remote_version: "1")
    gone = source.source_documents.create!(external_id: "gone", remote_version: "1", status: "missing")

    assert_equal [ stale ], source.stale_documents
    refute_includes source.stale_documents, gone, "a missing document is not waiting to be indexed"
  end
end
