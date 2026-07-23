require "test_helper"

# Integration: the deploy-lane intents that bin/release prepare/ship auto-record
# (Release::Conductor.record_deploy_intents!) must drive the LIVE "who's on it now"
# crew slot on /deployments END TO END — the record write (the conductor, on the
# prod board) → the board read (StageAgentsHelper#crew_columns / #in_progress_work),
# with NO hand-run `bin/task intent`. Born from the 2026-06-25 incident where a
# missed manual ship intent left the ship crew slot a blank dashed placeholder
# mid-deploy. ActionView::TestCase so the board helper is exercised for real.
# Lanes re-homed 2026-07-22: Avi QAs the assembled RC (qa-release); Steffon ships.
class DeployLaneIntentsTest < ActionView::TestCase
  include StageAgentsHelper

  setup do
    @avi     = Agent.create!(name: "Avi", slug: "avi", avatar: "https://example.com/avi.png")
    @steffon = Agent.create!(name: "Steffon", slug: "steffon")
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

  # An assembled (QA-green) release with one member — what ship/prepare-re-run
  # fire over: sweep records membership, qa_green! flips it assembled.
  def green_release_with(task)
    rel = Release::Conductor.sweep!(task)
    Release::Conductor.qa_green!(rel)
    rel.reload
  end

  # What `bin/release ship` does: record the Steffon shipped intent over the assembled
  # RC. The assembled card reserves a 4th (ship) lane that is EMPTY until the intent
  # lands — exactly the slot the operator caught blank.
  test "ship's Steffon intent fills the assembled card's empty ship slot, live" do
    rel    = green_release_with(member_task("alpha")) # swept + QA-green → assembled
    member = rel.tasks.first

    assert_empty ship_slot(member).stacked, "no ship intent yet → empty reserved slot (the incident)"

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "steffon")

    slot = ship_slot(member)
    assert_equal %w[steffon], slot.stacked.map { |a| a.agent&.slug }, "Steffon's ship intent fills the 4th slot"
    assert slot.live_since.present?, "the ship slot ticks live from the recorded intent"
  end

  # A member ALREADY past the QA-green flip (a straggler re-riding, or a prepare
  # re-run): the assembled transition EXISTS, so the prepare intent path must
  # STILL show Avi QA-ing LIVE on /deployments — driven only by
  # record_deploy_intents!, with NO hand-run `bin/task intent`.
  test "prepare's QA intent shows Avi QA live on /deployments for an already-assembled member" do
    rel    = green_release_with(member_task("std")) # past the QA-green flip (re-run/straggler)
    member = rel.tasks.first
    assert_equal "assembled", member.stage, "guard: the QA-green flip landed the assembled transition"

    before = assembled_slot(member)
    assert_equal %w[avi], before.stacked.map { |a| a.agent&.slug }, "Avi owns the assembled column"
    assert_nil before.live_since, "static (no live ticker) until prepare records the QA intent"

    # EXACTLY what `bin/release prepare` fires — no manual `bin/task intent`.
    slugs = Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "avi")
    assert_equal [member.slug], slugs, "the QA intent records even though the member is already assembled"

    live = assembled_slot(member)
    assert live.live_since.present?, "/deployments shows the assembled QA cluster ticking LIVE — Avi QA-ing"
    assert_equal %w[avi], live.stacked.map { |a| a.agent&.slug }, "Avi shown QA-ing live, no manual intent"
    # The reserved ship slot stays empty while only QA is live (Steffon hasn't started).
    assert_empty ship_slot(member).stacked, "the ship slot stays empty until Steffon's ship intent lands"
  end

  # THE STANDARD SHAPE at prepare time now: a swept member still `reviewed` (the
  # flip waits for QA-green). The plain toward-`assembled` QA intent drives the
  # live ticker.
  test "prepare's Avi intent drives the live QA ticker for a swept reviewed member" do
    member = member_task("qa")
    rel    = Release::Conductor.sweep!(member) # swept for QA, still `reviewed`

    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "avi")

    work = in_progress_work(member.reload, @by_slug, nil, member.task_events.select(&:intent?))
    refute_nil work, "the recorded QA intent surfaces as live work"
    assert_equal :assembled, work[:lane]
    assert_equal %w[avi], work[:agents].map { |a| a.agent&.slug }, "Avi QA-ing live"
  end

  # Once Steffon's ship intent is open, HE outranks Avi — actively shipping — and the
  # live ticker moves to the ship lane, leaving the assembled column static again.
  test "Steffon's open ship intent outranks the QA intent on an assembled member" do
    rel    = green_release_with(member_task("handoff"))
    member = rel.tasks.first
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "assembled", actor: "avi")     # QA live
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "steffon")   # ship starts

    assert_equal %w[steffon], ship_slot(member).stacked.map { |a| a.agent&.slug }, "the ship slot ticks Steffon"
    assert ship_slot(member).live_since.present?
    assert_nil assembled_slot(member).live_since, "QA yields the live ticker to the ship in progress"
  end

  # The intent is OPEN only until the real transition lands — then it's superseded
  # and the task is idle (no live ticker), so a re-record is a clean no-op.
  test "the real shipped transition supersedes the open ship intent" do
    rel = green_release_with(member_task("gamma"))
    Release::Conductor.record_deploy_intents!(rel.reload, to_stage: "shipped", actor: "steffon")
    member = rel.tasks.first
    assert member.reload.open_intent_for("shipped").present?, "open while still assembled"

    Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234")

    assert_nil member.reload.open_intent_for("shipped"), "ship! supersedes the intent"
    assert_nil in_progress_work(member, @by_slug, nil, member.task_events.select(&:intent?)),
               "a shipped task is idle — no live ticker"
  end
end
