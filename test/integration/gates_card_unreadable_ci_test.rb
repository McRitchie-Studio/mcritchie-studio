require "test_helper"
require Rails.root.join("bin/lib/ci_gate").to_s

# The OTHER end of /tasks/gate-logs-auth-as-red: what the task's gates card does
# with a ci row whose read was REFUSED on credentials.
#
# The record now stores `result: "unreadable"` instead of the false `"fail"`
# (bin/lib/ci_gate.rb). That is only half a fix. The card's glyph chain is
# fail → ✗, running → ◌, DEFAULT → ✓, so a new result value that reached that
# default would be painted with the PASS glyph — trading a manufactured failure for
# a manufactured success, which is the direction most of this family runs. These
# tests pin the fourth arm, on the real page, from the real GateRun row.
class GatesCardUnreadableCiTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  # The row bin/dor-check persists when an installation token expires mid-gate —
  # copied field-for-field from what the gate CLI is handed (CiStatus.gate_evidence
  # merged onto the ci sop), so the fixture cannot drift into a shape nothing writes.
  def unreadable_ci_sop
    { "sop" => "ci", "result" => GateRun::UNREADABLE_RESULT, "state" => "unreadable",
      "cause" => "credentials", "reason" => "gh: Bad credentials (HTTP 401)",
      "repo" => "McRitchie-Studio/mcritchie-studio", "at" => Time.current.iso8601 }
  end

  def refused_review(slug, sops)
    task = Task.create!(title: "gate record probe", stage: "submitted", slug: slug, metadata: {})
    GateRun.create!(subject_type: "task", subject_slug: slug, key: "dor_review", attempt: 1,
                    started_at: 3.minutes.ago, finished_at: 1.minute.ago, success: false, sops: sops)
    task
  end

  test "[integration] the gates card never paints an UNREADABLE ci row with the pass glyph" do
    task = refused_review("gates-card-unreadable", [unreadable_ci_sop])

    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    glyph = css_select("[data-result='unreadable'] [data-test='gate-sop-glyph']").first
    assert glyph, "the unreadable ci row must render — got #{css_select('[data-test=\'gate-sop-glyph\']').map(&:text).inspect}"
    refute_equal "✓", glyph.text.strip,
                 "a CI nobody could read is not a CI that passed — that is the inversion this arm exists to stop"
    refute_equal "✗", glyph.text.strip,
                 "and it is not the red bounce the record used to claim either"
    assert_equal "⚠", glyph.text.strip
  end

  # The control. If the ✗ arm broke, the test above would pass for the wrong reason
  # (everything would be ⚠) and a genuinely red CI would stop looking red.
  test "[integration] a genuinely failed ci row still paints the fail glyph" do
    task = refused_review("gates-card-red", [{ "sop" => "ci", "result" => "fail", "at" => Time.current.iso8601 }])

    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    assert_select "[data-result='fail'] [data-test='gate-sop-glyph']", text: "✗"
  end

  # THE PRODUCER AND THE RENDERER MUST AGREE ON THE WORD. bin/lib/ci_gate.rb is a
  # bin/ lib and cannot load this model, so the value exists twice — the same split
  # RUNNING_RESULT already lives with. If the two ever drift, the producer writes a
  # value the card does not recognise and the glyph chain falls through to its ✓
  # default, silently, with no test failing anywhere else.
  test "[unit] the producer's result value equals the one the card renders" do
    assert_equal GateRun::UNREADABLE_RESULT, CiGate::GATE_ROW_UNREADABLE,
                 "a drifted pair paints an unread CI green"
  end
end
