require "test_helper"
require "rake"
require "google/apis/drive_v3"

# [integration] The `workspace:walk` sweep across MULTIPLE tenants.
#
# The property: one source that the walker REFUSES must not cost every other
# tenant their walk. DriveWalker#call raises ArgumentError for a source with no
# workspace_account, or one whose workspace is not active, and those raises sit
# OUTSIDE the walker's own rescue by design — so the sweep is the only thing
# that can contain them. Two independent reviewers reached this defect; before
# the fix, one unbound source aborted the whole sweep with a backtrace.
class WorkspaceWalkRakeTest < ActiveSupport::TestCase
  Drive = Google::Apis::DriveV3

  class TreeClient
    def paged(query:)
      folder = query[/'([^']+)' in parents/, 1]
      return [] unless folder == "good-root"

      [ Drive::File.new(id: "doc-1", name: "Agreement.pdf", mime_type: "application/pdf",
                        version: 3, modified_time: DateTime.new(2026, 9, 1), size: 10,
                        web_view_link: "https://drive.example.test/doc-1", parents: [ "good-root" ],
                        owners: [ Drive::User.new(email_address: "o@example.test") ],
                        capabilities: Drive::File::Capabilities.new(can_edit: false)) ]
    end
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspace:walk")
    @exit_status = nil
  end

  def source(name:, root:, account:)
    KnowledgeSource.create!(kind: "google_drive", name: name, external_root_id: root,
                            entity: "e-#{root}", access: {}, workspace_account: account)
  end

  def run_walk
    Rake::Task["workspace:walk"].reenable
    Workspace::Credentials.stub(:configured?, true) do
      Workspace::DriveClient.stub(:new, ->(subject:) { TreeClient.new }) do
        capture_io do
          begin
            Rake::Task["workspace:walk"].invoke(nil)
          rescue SystemExit => e
            @exit_status = e.status
          end
        end
      end
    end
  end

  test "a REFUSED source does not cost the other tenants their walk" do
    # The refusing source is created FIRST, so before the fix its raise escaped
    # the map before the healthy one was ever reached.
    pending_ws = WorkspaceAccount.create!(domain: "notyet.test")          # pending — refused
    bad = source(name: "Unproven folder", root: "bad-root", account: pending_ws)

    live = WorkspaceAccount.create!(domain: "proven.test")
    live.mark_verified!
    good = source(name: "Proven folder", root: "good-root", account: live)

    out, err = run_walk

    assert_equal 1, good.source_documents.count, "the HEALTHY tenant was still walked"
    assert_equal 0, bad.source_documents.count
    assert_includes err, "WALK REFUSED"
    assert_includes err, "not active", "the walker's REMEDY text survives, verbatim"
    assert_includes out, "Proven folder"
    assert_equal 1, @exit_status, "a sweep with a refused source still exits non-zero"
  end

  test "a source with NO workspace at all is refused the same way" do
    orphan = source(name: "Unbound folder", root: "bad-root", account: nil)

    _out, err = run_walk

    assert_includes err, "WALK REFUSED"
    assert_includes err, "no workspace_account"
    assert_equal 0, orphan.source_documents.count
  end

  test "a foreign failure reports as a SLUG, never as raw vendor prose" do
    live = WorkspaceAccount.create!(domain: "boom.test")
    live.mark_verified!
    src = source(name: "Exploding folder", root: "good-root", account: live)
    exploder = Class.new do
      def paged(query:) = raise(StandardError, "surprise: team@boom.test and -----BEGIN PRIVATE KEY-----")
    end

    Rake::Task["workspace:walk"].reenable
    _out, err = Workspace::Credentials.stub(:configured?, true) do
      Workspace::DriveClient.stub(:new, ->(subject:) { exploder.new }) do
        capture_io do
          begin
            Rake::Task["workspace:walk"].invoke(nil)
          rescue SystemExit
            nil
          end
        end
      end
    end

    refute_includes err, "BEGIN PRIVATE KEY"
    refute_includes err, "team@boom.test"
    # "surprise" is the fault token and is meant to survive; the address and the
    # key are what must not.
    assert_equal "StandardError: surprise", src.reload.last_walk_error,
      "the DURABLE column holds a slug too"
    refute_includes src.last_walk_error, "team@boom.test"
    refute_includes src.last_walk_error, "BEGIN PRIVATE KEY"
  end
end
