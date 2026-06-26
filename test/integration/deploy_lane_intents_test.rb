require "test_helper"

# Integration: the deploy-lane intents that bin/release prepare/ship auto-record
# (Release::Conductor.record_deploy_intents!) must drive the LIVE "who's on it now"
# crew slot on /deployments END TO END — the record write (the conductor, on the
# prod board) → the board read (StageAgentsHelper#crew_columns / #in_progress_work),
# with NO hand-run `bin/task intent`. Born from the 2026-06-25 incident where a
# missed manual ship intent left the ship crew slot a blank dashed placeholder
# mid-deploy. ActionView::TestCase so the board helper is exercised for real.
class DeployLaneIntentsTest < ActionView::TestCase
  include StageAgentsHelper

  setup do
    @steffon = Agent.create!(name: "Steffon", slug: "steffon", avatar: "https://example.com/steffon.png")
    @avi     = Agent.create!(name: "Avi", slug: "avi")
    @agents  = Agent.all.to_a
    @by_slug = @agents.index_by(&:slug)
  end

  def member_task(label, stage: "reviewed")
    Task.create!(title: "deploy intent #{label} task", stage: stage,
                 metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"] } })
  end

  def ship_slot(task)
    deploy_slot(task, :shipped)
  end

  def assembled_slot(task)
    deploy_slot(task, :assembled)
  end

  def deploy_slot(task, lane)
    crew_columns(task.reload, stage_agent_groups(task, @agents), board: :deploy, agents: @agents)
      .find { |c| c.lane == lane }
  end

  # What `bin/release ship` does: record the Avi shipped intent over the assembled
  # RC. The assembled card reserves a 4th (ship) lane that is EMPTY until the intent
  # lands — exactly the slot the operator caught blank.
  test "ship's Avi intent fills the assembled card's empty ship slot, live" do
    rel    = Release::Conductor.adopt!(member_task("alpha")) # member → assembled at merge
    member = rel.tasks.first

    assert_empty ship_slot(member).stacked, "no ship intent yet → empty reserved slot (the incident)"

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")

    slot = ship_slot(member)
    assert_equal %w[avi], slot.stacked.map { |a| a.agent&.slug }, "Avi's ship intent fills the 4th slot"
    assert slot.live_since.present?, "the ship slot ticks live from the recorded intent"
  end

  # THE STANDARD FLOW — the reviewer's blocker. `bin/release merge` (Release::Conductor
  # .adopt!) already flips the member `reviewed → assembled` AT MERGE, so by the time
  # `bin/release prepare` runs the assembled transition EXISTS. The prepare intent path
  # must STILL show Steffon QA-ing LIVE on /deployments — driven only by
  # record_deploy_intents!, with NO hand-run `bin/task intent`.
  test "prepare's QA intent shows Steffon QA live on /deployments for an already-assembled member" do
    rel    = Release::Conductor.adopt!(member_task("std")) # bin/release merge semantics: member → assembled
    member = rel.tasks.first
    assert_equal "assembled", member.stage, "guard: the merge landed the assembled transition (the standard flow)"

    before = assembled_slot(member)
    assert_equal %w[steffon], before.stacked.map { |a| a.agent&.slug }, "Steffon owns the assembled column"
    assert_nil before.live_since, "static (no live ticker) until prepare records the QA intent"

    # EXACTLY what `bin/release prepare` fires — no manual `bin/task intent`.
    slugs = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon")
    assert_equal [member.slug], slugs, "the QA intent records even though the member is already assembled"

    live = assembled_slot(member)
    assert live.live_since.present?, "/deployments shows the assembled QA cluster ticking LIVE — Steffon QA-ing"
    assert_equal %w[steffon], live.stacked.map { |a| a.agent&.slug }, "Steffon shown QA-ing live, no manual intent"
    # The reserved ship slot stays empty while only QA is live (Avi hasn't started).
    assert_empty ship_slot(member).stacked, "the ship slot stays empty until Avi's ship intent lands"
  end

  # The rare half-state: a member still attached at `reviewed` at prepare time (not yet
  # merged). The plain toward-`assembled` QA intent drives the live ticker there too.
  test "prepare's Steffon intent drives the live QA ticker for a reviewed member" do
    rel    = Release.open!(slug: "rel-qa-intent")
    member = member_task("qa")
    member.update!(release_slug: rel.slug) # attached for QA, still `reviewed`

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon")

    work = in_progress_work(member.reload, @by_slug, nil, member.task_events.select(&:intent?))
    refute_nil work, "the recorded QA intent surfaces as live work"
    assert_equal :assembled, work[:lane]
    assert_equal %w[steffon], work[:agents].map { |a| a.agent&.slug }, "Steffon QA-ing live"
  end

  # Once Avi's ship intent is open, HE outranks Steffon — actively shipping — and the
  # live ticker moves to the ship lane, leaving the assembled column static again.
  test "Avi's open ship intent outranks the QA intent on an assembled member" do
    rel    = Release::Conductor.adopt!(member_task("handoff"))
    member = rel.tasks.first
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "steffon") # QA live
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")       # ship starts

    assert_equal %w[avi], ship_slot(member).stacked.map { |a| a.agent&.slug }, "the ship slot ticks Avi"
    assert ship_slot(member).live_since.present?
    assert_nil assembled_slot(member).live_since, "QA yields the live ticker to the ship in progress"
  end

  # The intent is OPEN only until the real transition lands — then it's superseded
  # and the task is idle (no live ticker), so a re-record is a clean no-op.
  test "the real shipped transition supersedes the open ship intent" do
    rel = Release::Conductor.adopt!(member_task("gamma"))
    rel.assemble!
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "avi")
    member = rel.tasks.first
    assert member.reload.open_intent_for("shipped").present?, "open while still assembled"

    Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234")

    assert_nil member.reload.open_intent_for("shipped"), "ship! supersedes the intent"
    assert_nil in_progress_work(member, @by_slug, nil, member.task_events.select(&:intent?)),
               "a shipped task is idle — no live ticker"
  end
end
