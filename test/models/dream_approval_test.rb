# frozen_string_literal: true

require "test_helper"
require Rails.root.join("bin/lib/dream_bank").to_s

# [unit] DreamApproval: who may approve, what may be approved, and how a recorded
# approval stops being pending once the file reads approved.
class DreamApprovalTest < ActiveSupport::TestCase
  # The fixture carries no slug (fixtures skip Sluggable); a real account has one.
  setup { users(:alex).update_column(:slug, "alex-mcritchie-test") }

  def dream(slug: "some-dream", home: "carl", status: "proposed")
    DreamBank::Dream.new(slug: slug, home: home, status: status, question: "Q?", answer: "A.", why: "",
                         tags: {}, source: "", story: "")
  end

  test "[unit] only Alex's admin account approves; another admin or a viewer does not" do
    assert DreamApproval.approver?(users(:alex))
    assert_not DreamApproval.approver?(users(:viewer))
    assert_not DreamApproval.approver?(nil)

    seat = User.create!(email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin")
    assert seat.admin?
    assert_not DreamApproval.approver?(seat), "an agent seat holds admin; admin alone is not enough"

    demoted = users(:alex).tap { |user| user.role = "viewer" }
    assert_not DreamApproval.approver?(demoted), "the approver must still be an admin"
  end

  test "[unit] record! records a proposed dream once, naming the approver" do
    first = DreamApproval.record!(dream, users(:alex))
    second = DreamApproval.record!(dream, users(:alex))

    assert_equal first, second, "a second click returns the first row"
    assert_equal 1, DreamApproval.count
    assert_equal [ "carl", "some-dream" ], [ first.dream_home, first.dream_slug ]
    assert_equal "alex-mcritchie-test", first.approved_by_slug
    assert_equal users(:alex), first.approved_by
    assert_not_nil first.approved_at
    assert_nil first.applied_at
  end

  test "[unit] record! refuses a dream that is not proposed, a missing dream, and a non-approver" do
    assert_raises(DreamApproval::NotApprovable) { DreamApproval.record!(dream(status: "approved"), users(:alex)) }
    assert_raises(DreamApproval::NotApprovable) { DreamApproval.record!(nil, users(:alex)) }
    assert_raises(DreamApproval::NotApprovable) { DreamApproval.record!(dream, users(:viewer)) }
    assert_equal 0, DreamApproval.count
  end

  test "[unit] reconcile! stamps applied only where the file now reads approved" do
    flipped = DreamApproval.record!(dream(slug: "flipped"), users(:alex))
    waiting = DreamApproval.record!(dream(slug: "waiting"), users(:alex))
    same_slug_elsewhere = DreamApproval.record!(dream(slug: "flipped", home: "xan"), users(:alex))

    stamped = DreamApproval.reconcile!([ dream(slug: "flipped", status: "approved"), dream(slug: "waiting"),
                                         dream(slug: "flipped", home: "xan") ])

    assert_equal 1, stamped
    assert_not_nil flipped.reload.applied_at
    assert_nil waiting.reload.applied_at
    assert_nil same_slug_elsewhere.reload.applied_at, "a dream is keyed by home and slug"
    assert_equal [ "carl/waiting", "xan/flipped" ], DreamApproval.pending_by_key([]).keys.sort
  end

  test "[unit] the pending read names the deployed file's status, or missing" do
    row = DreamApproval.record!(dream, users(:alex))

    assert_equal "proposed", row.as_pending_json(dream)[:file_status]
    assert_equal "missing", row.as_pending_json(nil)[:file_status]
    assert_equal "carl/some-dream.md", row.as_pending_json(dream)[:path]
  end
end
