require "test_helper"

# Integration: the /deployments release tracker must never reach "Live on QA"
# (`qa_deployed`) before the swept members actually flip `reviewed → assembled`.
#
# The bug this pins: `bin/release prepare` used to stamp deploy_qa:completed via
# record_qa_deploy at step 7 — BEFORE run_post_deploy (8a) and the qa_green! flip
# (8b) — so a viewer (and a mid-run failure) could see a green Live-on-QA while
# the members were still `reviewed`. The stamp now lives inside qa_green!, atomic
# with the flip, so the release-level tracker and the task-level stage move as one.
# Exercises Conductor + Release + the DB stage-timeline together.
class QaGreenStampOrderingTest < ActiveSupport::TestCase
  def reviewed_member(label = "alpha")
    Task.create!(title: "reviewable #{label} demo task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"] } })
  end

  test "[integration] the tracker does not reach Live-on-QA until the members flip" do
    member = reviewed_member
    rel = Release::Conductor.sweep!(member) # member attached, still reviewed

    # Step 7 (record_qa_url): the board header gets its QA link while the deploy is
    # still in flight — but this is the exact window where the OLD code lit
    # Live-on-QA green. The tracker must stay BELOW qa_deployed here.
    Release::Conductor.record_qa_url(release: rel, qa_url: "https://qa.mcritchie.studio/deployments")
    rel.reload
    assert_equal "reviewed", member.reload.stage, "member has NOT flipped yet"
    refute rel.stage_reached?("qa_deployed"),
           "Live-on-QA must not be green while the member is still reviewed (the regression)"

    # Step 8b (qa_green!): the flip AND the Live-on-QA stamp land together.
    Release::Conductor.qa_green!(rel, qa_url: rel.qa_url)
    rel.reload

    assert_equal "assembled", member.reload.stage, "member flipped reviewed → assembled"
    assert_equal "assembled", rel.state, "RC assembled"
    assert rel.stage_reached?("qa_deployed"),
           "Live-on-QA is green now — atomic with the member flip, never before it"
  end

  test "[integration] a not-green run (no qa_green!) leaves the tracker below Live-on-QA" do
    member = reviewed_member("bravo")
    rel = Release::Conductor.sweep!(member)
    Release::Conductor.record_qa_url(release: rel, qa_url: "https://qa.mcritchie.studio/deployments")

    # No qa_green! (a boot failure / aborted post-deploy hook): members stay
    # reviewed and the tracker must NOT falsely show Live-on-QA.
    rel.reload
    assert_equal "reviewed", member.reload.stage
    refute rel.stage_reached?("qa_deployed"),
           "a run that never reached QA-green leaves Live-on-QA dark for the self-healing re-run"
  end
end
