require "test_helper"
require "rake"

# [unit] workspace:shortcuts names what each walked shortcut opens and says when no
# source indexes it, because the walker never follows one.
class WorkspaceShortcutsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspace:shortcuts")
    Rake::Task["workspace:shortcuts"].reenable
    @source = KnowledgeSource.create!(kind: "google_drive", name: "Brand", external_root_id: "brand-root")
  end

  def shortcut(target)
    @source.source_documents.create!(external_id: "sc", title: "Agreements", status: "active",
                                     mime_type: Workspace::DriveWalker::SHORTCUT_MIME,
                                     metadata: { "shortcut_target_id" => target })
  end

  def output = capture_io { Rake::Task["workspace:shortcuts"].invoke }.first

  test "it says when nothing indexes the target, and how to fix it" do
    shortcut("master")
    assert_match(/Agreements -> master — NOT INDEXED.*workspace:add_source/, output)
  end

  test "it names the source that indexes the target" do
    shortcut("master")
    KnowledgeSource.create!(kind: "google_drive", name: "Signer", external_root_id: "master", last_walked_at: Time.current)
    assert_match(/indexed by #\d+ Signer/, output)
  end

  test "it ignores a document that is not a shortcut" do
    @source.source_documents.create!(external_id: "doc", title: "Doc", status: "active", mime_type: "application/pdf")
    assert_match(/no shortcuts walked/, output)
  end
end
