# frozen_string_literal: true

require "test_helper"
require Rails.root.join("bin/lib/dream_bank").to_s

# [unit] DreamRetirement: only Alex retires, only an approved dream, and a recorded
# retirement stops being pending once the deployed bank no longer holds the file.
class DreamRetirementTest < ActiveSupport::TestCase
  setup { users(:alex).update_column(:slug, "alex-mcritchie-test") }

  def dream(slug: "old-dream", home: "carl", status: "approved")
    DreamBank::Dream.new(slug: slug, home: home, status: status, question: "Q?", answer: "A.", why: "",
                         tags: {}, source: "", story: "")
  end

  test "[unit] only Alex retires, and only an approved dream" do
    error = assert_raises(DreamRetirement::NotRetirable) { DreamRetirement.record!(dream, users(:viewer)) }
    assert_includes error.message, "only Alex"
    seat = User.create!(email: "admin@mcritchie.studio", name: "Admin McRitchie", role: "admin")
    assert_raises(DreamRetirement::NotRetirable) { DreamRetirement.record!(dream, seat) }
    error = assert_raises(DreamRetirement::NotRetirable) { DreamRetirement.record!(dream(status: "proposed"), users(:alex)) }
    assert_includes error.message, "not approved"
    assert_raises(DreamRetirement::NotRetirable) { DreamRetirement.record!(nil, users(:alex)) }
    assert_equal 0, DreamRetirement.count
  end

  test "[unit] record! is idempotent and names the approver" do
    first = DreamRetirement.record!(dream, users(:alex))
    again = DreamRetirement.record!(dream, users(:alex))

    assert_equal first.id, again.id
    assert_equal "alex-mcritchie-test", first.retired_by_slug
    assert_equal "carl/old-dream", first.key
  end

  test "[unit] reconcile stamps a row applied once its file is gone, and never on an unread bank" do
    row = DreamRetirement.record!(dream, users(:alex))
    other = dream(slug: "kept")

    assert_equal 0, DreamRetirement.reconcile!([]), "an empty bank is an unread bank"
    assert_equal({ "carl/old-dream" => row }, DreamRetirement.pending_by_key([ dream, other ]))
    assert_nil row.reload.applied_at

    assert_equal({}, DreamRetirement.pending_by_key([ other ]))
    assert_not_nil row.reload.applied_at
  end
end
