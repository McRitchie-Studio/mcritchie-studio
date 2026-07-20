require "test_helper"

# Integration: the model-level behavior `bin/release finalize` (and a `ship`
# --finalize-only re-run) rests on — the recovery for a github_actions ship whose
# watch-process was KILLED while GitHub Actions finished the deploy independently,
# stranding the board at `assembled`.
#
# The pure decisions (Release::ShipSequence.deploy_already_succeeded? /
# finalize_pending?) are unit-tested; this proves they COMPOSE correctly against a
# real Release + Task DB, and — the load-bearing invariant — that finalize_pending?'s
# :ship gate is EXACTLY the boundary at which Release::Conductor.ship! stops being a
# safe re-run (it raises "already terminal" once fully shipped). So the gate is what
# makes a re-run of finalize a clean no-op, not luck.
class ResumableFinalizeTest < ActionDispatch::IntegrationTest
  S = Release::ShipSequence

  def app_reviewed(title, repo: "mcritchie-studio")
    Task.create!(title: title, stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [repo] } })
  end

  # The signals bin/release's finalize read gathers off the release, computed the
  # same way here so the test drives the exact production decision.
  def pending_for(rel)
    rel.reload
    S.finalize_pending?(
      state: rel.state,
      sealed: rel.smoke_sealed?,
      notes_completed: rel.event_completed?("release_notes"),
      members_all_shipped: rel.tasks.where.not(stage: "shipped").empty?
    )
  end

  def assembled_release(*titles)
    tasks = titles.map { |t| app_reviewed(t) }
    rel = Release::Conductor.sweep!(tasks.first)
    tasks.drop(1).each { |t| Release::Conductor.sweep!(t) }
    Release::Conductor.prepare!(task_slugs: [])
    assert_equal "assembled", rel.reload.state, "sanity: the release must reach the assembled strand"
    [rel, tasks]
  end

  test "[integration] a fully-stranded (assembled) release needs seal+ship+notes; Conductor.ship! finalizes it" do
    rel, (a, b) = assembled_release("Finalize member alpha", "Finalize member beta")

    # THE STRAND: deploy landed, board at assembled, nothing recorded.
    assert_equal %i[seal ship notes], pending_for(rel)

    # finalize's :ship step — Conductor.ship! — flips the strand to shipped.
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "steffon")
    assert_equal "shipped", rel.reload.state
    assert_equal %w[shipped shipped], [a.reload.stage, b.reload.stage]

    # :ship drops now (shipped + all members flipped); seal/notes stay (unrun here) —
    # finalize composes step by step, it does not re-run what's done.
    assert_equal %i[seal notes], pending_for(rel)
  end

  test "[integration] a SECOND Conductor.ship! on a fully-shipped release RAISES — the gate's necessity" do
    rel, = assembled_release("Ship once member alpha", "Ship once member beta")
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234")
    assert_equal "shipped", rel.reload.state

    # finalize_pending? drops :ship here for a REASON: ship! is no longer a safe
    # re-run. This is the exact guard that keeps `finalize` idempotent.
    assert_not_includes pending_for(rel), :ship
    assert_raises(ArgumentError) do
      Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234")
    end
  end

  test "[integration] a kill MID member-cadence keeps :ship pending, and ship! RESUMES the straggler" do
    rel, (a, b) = assembled_release("Straggler member alpha", "Straggler member beta")
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234")
    assert_equal %w[shipped shipped], [a.reload.stage, b.reload.stage]

    # Simulate the kill landing between member flips: release shipped, one member
    # still un-flipped in the DB.
    b.update_column(:stage, "assembled")
    assert_not rel.reload.tasks.where.not(stage: "shipped").empty?, "sanity: a straggler remains"

    # :ship STAYS pending (members_all_shipped=false), and this time ship! RESUMES
    # rather than raising — the resumable-member path.
    assert_includes pending_for(rel), :ship
    assert_nothing_raised { Release::Conductor.ship!(release: rel.reload, deployed_sha: "abc1234") }
    assert_equal "shipped", b.reload.stage
    assert_not_includes pending_for(rel), :ship
  end

  test "[integration] a fully-finalized release reports NO pending steps (the clean no-op)" do
    rel, = assembled_release("Done member alpha task")
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234")
    rel.record_smoke_seal!(Release::SmokeSeal.from_result(passed: true, summary: "green"))
    rel.record_event!(step: "release_notes", status: "completed", source: "conductor",
                      idempotency_key: "#{rel.slug}:release_notes:completed")

    assert_equal [], pending_for(rel), "shipped + sealed + notes delivered ⇒ finalize is a clean no-op"
  end
end
