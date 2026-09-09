require "test_helper"
require Rails.root.join("bin/lib/ci_gate").to_s

# The OTHER end of /tasks/refused-review-records-fail: what the task's gates card does
# with a ci row whose CI never gave a verdict.
#
# The record now stores `no_checks` / `unverified` instead of the false `"fail"`
# (bin/lib/ci_gate.rb). THAT IS ONLY HALF A FIX, and the missing half runs the defect
# BACKWARDS. The card's glyph chain is fail → ✗, running → ◌, DEFAULT → ✓, so a result
# value that reaches the default is painted with the PASS glyph: correcting the record
# alone would have turned a manufactured failure into a manufactured success, which is
# the direction most of this family runs. Proven by mutation on the sibling PR (#1305):
# with the record already corrected, dropping the view arm rendered the row ✓.
#
# These tests pin the arm on the real page, from a real GateRun row, per value — not
# once for the set, so removing ONE member from NO_VERDICT_RESULTS cannot hide behind
# its siblings.
class GatesCardNoVerdictCiTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  def refused_review(slug, sops)
    task = Task.create!(title: "gate record probe", stage: "submitted", slug: slug, metadata: {})
    GateRun.create!(subject_type: "task", subject_slug: slug, key: "dor_review", attempt: 1,
                    started_at: 3.minutes.ago, finished_at: 1.minute.ago, success: false, sops: sops)
    task
  end

  def glyph_for(task, result)
    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    node = css_select("[data-result='#{result}'] [data-test='gate-sop-glyph']").first
    assert node, "the #{result} ci row must render — got " \
                 "#{css_select('[data-test=\'gate-sop-glyph\']').map(&:text).inspect}"
    node.text.strip
  end

  # EVERY no-verdict value, one page load each, driven off the PRODUCER's own list so a
  # value added to the family without a card arm reddens here rather than shipping as a
  # silent ✓.
  test "[integration] the gates card never paints a NO-VERDICT ci row with the pass glyph" do
    CiGate::GATE_ROW_NO_VERDICT.each do |result|
      task = refused_review("gates-card-#{result.tr('_', '-')}",
                            [{ "sop" => "ci", "result" => result, "at" => Time.current.iso8601 }])
      glyph = glyph_for(task, result)

      refute_equal "✓", glyph,
                   "#{result}: a CI that never gave a verdict is not a CI that passed — " \
                   "that is the inversion this arm exists to stop"
      refute_equal "✗", glyph, "#{result}: and it is not the red bounce the record used to claim either"
      assert_equal "⚠", glyph
    end
  end

  # The control. If the ✗ arm broke, the test above would pass for the wrong reason
  # (everything would be ⚠) and a genuinely red CI would stop looking red.
  test "[integration] a genuinely failed ci row still paints the fail glyph" do
    task = refused_review("gates-card-nv-red", [{ "sop" => "ci", "result" => "fail", "at" => Time.current.iso8601 }])

    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    assert_select "[data-result='fail'] [data-test='gate-sop-glyph']", text: "✗"
  end

  # THE SECOND CONTROL, and the reason the arm is a SET MEMBERSHIP rather than "anything
  # that is not fail". A row that really did pass must still reach the ✓ default —
  # otherwise the fix is "paint everything amber", which loses the same information in
  # the opposite direction.
  test "[integration] a passing sop row still paints the pass glyph" do
    task = refused_review("gates-card-nv-pass", [{ "sop" => "ci", "result" => "pass", "at" => Time.current.iso8601 }])

    assert_equal "✓", glyph_for(task, "pass")
  end

  # THE PRODUCER AND THE RENDERER MUST AGREE ON THE WORDS. bin/lib/ci_gate.rb is a bin/
  # lib and cannot load this model, so the values exist twice — the same split
  # RUNNING_RESULT already lives with. If the two lists ever drift, the producer writes
  # a value the card does not recognise and the glyph chain falls through to its ✓
  # default, silently, with no test failing anywhere else.
  test "[unit] the producer's no-verdict values equal the ones the card paints" do
    assert_equal GateRun::NO_VERDICT_RESULTS.sort, CiGate::GATE_ROW_NO_VERDICT.sort,
                 "a drifted pair paints a CI with no verdict green"
    assert_equal GateRun::UNREADABLE_RESULT, CiGate::GATE_ROW_UNREADABLE
    assert_equal GateRun::NO_CHECKS_RESULT, CiGate::GATE_ROW_NO_CHECKS
    assert_equal GateRun::UNVERIFIED_RESULT, CiGate::GATE_ROW_UNVERIFIED
  end

  # THE LIST IS A MIRROR OF THE STATE FAMILY, and this is what keeps it one. Every
  # member of CI_NO_VERDICT_STATES must land on a value the card paints ⚠; a member
  # added without its own `when` arm falls through gate_row's `else` and lands on a
  # "fail"/"unverified" pair that this assertion rejects.
  test "[unit] every no-verdict CI state maps onto a value the card paints amber" do
    CiGate::CI_NO_VERDICT_STATES.each do |state|
      row = CiGate.gate_row({ state: state }, review_role: true, review_refused: true)

      assert_includes GateRun::NO_VERDICT_RESULTS, row,
                      "#{state} records #{row.inspect}, which the gates card paints with the ✓ default"
    end
  end
end
