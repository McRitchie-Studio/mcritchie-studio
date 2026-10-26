require "test_helper"
require "tmpdir"

# Release::Retro — the post-ship "review & learn" step's data-gathering + doc
# rendering. UNIT coverage of gather/render/resolve/helpers, an INTEGRATION test
# of the full DB→render→file pipeline (write_doc), and a NON-BLOCKING proof that
# archive is unaffected by whether a retro was run.
class Release::RetroTest < ActiveSupport::TestCase
  # A shipped release with member tasks carrying controlled TaskEvent spines, so
  # gather reads real timing/rework/reviewers off the append-only log.
  def shipped_release(slug: "rel-retro-test")
    Release.create!(slug: slug, state: "shipped", branch: "release", confirmed_by: "alex")
  end

  # Build a member task + an explicit event spine with controlled timestamps.
  # The task is left at `reviewed`; membership is by release_slug (gather reads
  # events + devops, not task.stage), so the spine timing stays deterministic.
  def member(release, title:, repo: "mcritchie-studio", shape: "backend",
             submitted_at:, shipped_at: nil, blocked: 0, reviewers: nil, checks: [])
    task = Task.create!(
      title: title, stage: "reviewed", release_slug: release.slug,
      metadata: { "devops" => { "shape" => shape, "repositories" => [repo], "checks_run" => checks } }
    )
    task.task_events.create!(from_stage: "building", to_stage: "submitted", occurred_at: submitted_at)
    task.task_events.create!(from_stage: "submitted", to_stage: "reviewed",
                             occurred_at: submitted_at + 30.minutes,
                             metadata: reviewers ? { "reviewers" => reviewers } : {})
    # A block is a `building` attribute now (no →blocked TaskEvent). The durable
    # per-round marker is the qa_feedback Activity, which is what rework_rounds
    # counts — one per bounce.
    blocked.times do |i|
      Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                       description: "rework round #{i}", created_at: submitted_at + (40 + i).minutes)
    end
    task.task_events.create!(from_stage: "assembled", to_stage: "shipped", occurred_at: shipped_at) if shipped_at
    task
  end

  # --- unit: gather --------------------------------------------------------

  test "gather builds per-member records with timing, rework, reviewers, and checks" do
    rel = shipped_release
    base = Time.utc(2026, 6, 20, 12, 0, 0)
    member(rel, title: "Retro member one", submitted_at: base, shipped_at: base + 2.hours,
           blocked: 1, reviewers: %w[avi carl], checks: ["[unit] a", "[integration] b"])

    data = Release::Retro.gather(rel)

    assert_equal "rel-retro-test", data["slug"]
    assert_equal "shipped", data["state"]
    assert_equal "alex", data["confirmed_by"]
    assert_equal 1, data["members"].size

    m = data["members"].first
    assert_equal "feature", m["kind"]
    assert_equal "mcritchie-studio", m["repo"]
    assert_equal 7200, m["cycle_seconds"], "submitted→shipped is 2h"
    assert_equal 1, m["rework_rounds"], "one bounce into blocked"
    assert_equal %w[avi carl], m["reviewers"], "reviewers read off the submitted→reviewed event"
    assert_equal ["[unit] a", "[integration] b"], m["checks_run"]
  end

  test "gather totals roll up cycle time and rework across members" do
    rel = shipped_release
    base = Time.utc(2026, 6, 20, 12, 0, 0)
    member(rel, title: "Retro totals one", submitted_at: base, shipped_at: base + 1.hour, blocked: 1)
    member(rel, title: "Retro totals two", submitted_at: base, shipped_at: base + 2.hours, blocked: 2)

    totals = Release::Retro.gather(rel)["totals"]
    assert_equal 2, totals["members"]
    assert_equal 10_800, totals["cycle_seconds"], "1h + 2h"
    assert_equal 3, totals["rework_rounds"], "1 + 2 blocks"
  end

  test "cycle_seconds is nil when the shipped event is missing" do
    rel = shipped_release
    base = Time.utc(2026, 6, 20, 12, 0, 0)
    m = member(rel, title: "Retro no ship", submitted_at: base, shipped_at: nil)

    record = Release::Retro.member_record(m)
    assert_nil record["cycle_seconds"], "no shipped event → unknown duration, not a guess"
  end

  # --- unit: render --------------------------------------------------------

  test "render emits all the expected doc sections from a gathered record" do
    rel = shipped_release
    base = Time.utc(2026, 6, 20, 12, 0, 0)
    member(rel, title: "Retro render one", submitted_at: base, shipped_at: base + 90.minutes,
           reviewers: %w[avi], checks: ["[unit] x"])

    md = Release::Retro.render(Release::Retro.gather(rel),
                               answers: { "worked" => ["fast review"],
                                          "friction" => ["flaky e2e"],
                                          "followups" => ["fix the flake"] })

    assert_includes md, "# Release Retro — rel-retro-test"
    assert_includes md, "## Summary"
    assert_includes md, "## Members"
    assert_includes md, "| Task | Kind | Repo | Cycle | Rework | Reviewers |"
    assert_includes md, "1h 30m", "cycle time is humanized in the members table"
    assert_includes md, "## Recorded checks"
    assert_includes md, "[unit] x"
    assert_includes md, "## What worked well"
    assert_includes md, "- fast review"
    assert_includes md, "## What caused friction"
    assert_includes md, "- flaky e2e"
    assert_includes md, "## Follow-ups"
    assert_includes md, "- fix the flake"
  end

  test "render shows none-recorded placeholders when answers are blank" do
    rel = shipped_release
    member(rel, title: "Retro blank answers", submitted_at: Time.utc(2026, 6, 20, 12), shipped_at: Time.utc(2026, 6, 20, 13))

    md = Release::Retro.render(Release::Retro.gather(rel), answers: {})
    assert_includes md, "_(none recorded)_"
  end

  # --- unit: resolve + helpers --------------------------------------------

  test "resolve prefers an explicit slug, then last_shipped when none is active" do
    shipped = shipped_release(slug: "rel-resolve-shipped")

    assert_equal shipped, Release::Retro.resolve("rel-resolve-shipped")
    assert_nil Release::Retro.resolve("does-not-exist")
    # No active release → falls back to the most-recently-shipped one.
    assert_equal shipped, Release::Retro.resolve(nil)
    assert_equal shipped, Release::Retro.resolve("")
  end

  test "resolve prefers the current active release over last_shipped" do
    shipped_release(slug: "rel-resolve-old-ship")
    active = Release.open!(slug: "rel-resolve-active")
    assert_equal active, Release::Retro.resolve(nil)
  end

  test "humanize_duration formats compactly and handles nil" do
    assert_equal "—", Release::Retro.humanize_duration(nil)
    assert_equal "0s", Release::Retro.humanize_duration(0)
    assert_equal "45m", Release::Retro.humanize_duration(45 * 60)
    assert_equal "1h 30m", Release::Retro.humanize_duration(90 * 60)
    assert_equal "2d 3h", Release::Retro.humanize_duration((2 * 86_400) + (3 * 3_600))
  end

  # --- integration: full DB → render → file pipeline -----------------------

  test "write_doc writes a durable retro doc with all sections to disk" do
    rel = shipped_release(slug: "rel-writedoc")
    base = Time.utc(2026, 6, 20, 12, 0, 0)
    member(rel, title: "Write doc member", submitted_at: base, shipped_at: base + 3.hours,
           reviewers: %w[avi carl], checks: ["[unit] gather", "[integration] write"])

    Dir.mktmpdir do |root|
      path = Release::Retro.write_doc(rel, root: root, dir: "audits",
                                      answers: { "worked" => ["clean handoff"],
                                                 "followups" => ["backfill events"] })

      assert_equal File.join(root, "audits", "retro-rel-writedoc.md"), path
      assert File.exist?(path), "the retro doc is written to disk"
      body = File.read(path)
      assert_includes body, "# Release Retro — rel-writedoc"
      assert_includes body, "write-doc-member", "the member task appears by its slug"
      assert_includes body, "3h", "cycle time appears in the members table"
      assert_includes body, "[unit] gather"
      assert_includes body, "- clean handoff"
      assert_includes body, "- backfill events"
    end
  end

  # --- non-blocking: archive is unaffected by retro ------------------------

  test "archive_completed! works the same whether or not a retro doc was written" do
    last = shipped_release(slug: "rel-archive-last")
    keeper = member(last, title: "Archive keeper member", submitted_at: Time.utc(2026, 6, 20, 12))
    keeper.update!(stage: "shipped")
    # An older shipped task in NO release — the archivable one.
    old = Task.create!(title: "Old shipped chore task", stage: "shipped",
                       metadata: { "devops" => { "shape" => "backend", "repositories" => ["mcritchie-studio"] } })

    # Writing a retro doc must not change archive behavior in any way.
    Dir.mktmpdir do |root|
      Release::Retro.write_doc(last, root: root, dir: "audits", answers: {})
    end

    result = Release::Conductor.archive_completed!
    assert_includes result[:archived], old.slug, "the non-member shipped task still archives"
    assert_equal "archived", old.reload.stage
    assert_equal "shipped", keeper.reload.stage, "last-release members stay shipped"
    # Retro writes no board/DB state, so there is nothing for archive to depend on.
    assert_equal [], Release::Retro.gather(last)["members"].map { |m| m["slug"] } - [keeper.slug]
  end
end
