require "test_helper"

# [unit] ApplicationHelper#release_repo_lanes — the per-repo /deployments tracker. One
# lane per member repo, each with four phase meters. The load-bearing invariant is that
# the QA/Deploying meters are gated by THIS release's own stage stamps (not a stray run
# for the repo), and Confirming is the coarse, release-grain meter.
class ReleaseLanesHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "[unit] one lane per member repo, apps vs libraries" do
    lanes = release_repo_lanes(lane_release("mcritchie-studio", "studio-engine"))

    assert_equal %w[mcritchie-studio studio-engine], lanes.map { |l| l[:repo] }.sort
    assert_equal "lib", lanes.find { |l| l[:repo] == "studio-engine" }[:kind]
    assert_equal "app", lanes.find { |l| l[:repo] == "mcritchie-studio" }[:kind]
    assert_equal 4, lanes.first[:phases].size, "four phase meters per lane"
  end

  test "[unit] ONE member spanning two repos earns a lane in each" do
    # The board's read side of the 2026-08-13 half-ship: the tracker listed lanes by
    # the singular Task#release_repo, so a member carrying [mcritchie-studio,
    # turf-monster] rendered ONE lane — the tracker under-reporting the release
    # exactly as the pipeline under-promoted it. An operator watching /deployments
    # saw a complete-looking board.
    rel = Release.open!
    Task.create!(title: "member spans two repos", stage: "reviewed", position: 10, release_slug: rel.slug,
                 metadata: { "devops" => { "repositories" => %w[mcritchie-studio turf-monster] } })

    lanes = release_repo_lanes(rel.reload)

    assert_equal %w[mcritchie-studio turf-monster], lanes.map { |l| l[:repo] }.sort
  end

  test "[unit] deploy meters are gated by the release's OWN stage, not a stray run" do
    rel = lane_release("mcritchie-studio")
    # A completed QA Deploy run exists for the repo, but the release has NOT entered QA.
    GithubWorkflowRun.create!(repo: "McRitchie-Studio/mcritchie-studio", workflow_name: "QA Deploy", run_id: 8_100,
                              status: "completed", conclusion: "success", head_branch: "main", head_sha: "z",
                              run_started_at: Time.current, html_url: "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/8100")
    states = ->(r) { release_repo_lanes(r).first[:phases].to_h { |p| [p[:key], p[:state]] } }

    s = states.call(rel)
    assert_equal :pending, s["qa_deploying"], "a stray run must NOT light QA before the release enters it"
    assert_equal :pending, s["confirming"]
    assert_equal :pending, s["production_deploying"]

    rel.stamp_stage!("qa_deploying")
    assert_equal :running, states.call(rel.reload)["qa_deploying"], "QA lights only once the release enters it"

    rel.stamp_stage!("qa_deployed")
    assert_equal :done, states.call(rel.reload)["qa_deploying"]

    rel.stamp_stage!("confirming")
    assert_equal :running, states.call(rel.reload)["confirming"], "Confirming is coarse, off the stamps"

    rel.stamp_stage!("prod_deploying")
    assert_equal :running, states.call(rel.reload)["production_deploying"]
  end

  test "[unit] a reached deploy meter carries the run link + flips to failed on a red run" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deploying")
    GithubWorkflowRun.create!(repo: "McRitchie-Studio/mcritchie-studio", workflow_name: "QA Deploy", run_id: 8_200,
                              status: "completed", conclusion: "failure", head_branch: "main", head_sha: "z",
                              run_started_at: Time.current, html_url: "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/8200")

    qa = release_repo_lanes(rel.reload).first[:phases].find { |p| p[:key] == "qa_deploying" }
    assert_equal :failed, qa[:state], "a completed-but-failed run flips the reached QA meter to failed"
    assert_equal "https://github.com/McRitchie-Studio/mcritchie-studio/actions/runs/8200", qa[:url]
  end

  test "[unit] a library shows Published, then n/a for the server-deploy phases" do
    phases = release_repo_lanes(lane_release("studio-engine")).first[:phases].to_h { |p| [p[:key], p] }

    assert_equal "Published", phases["published"][:label]
    assert_equal :na, phases["confirming"][:state]
    assert_equal :na, phases["deploying"][:state]
  end

  # ---- the live-fx signature (what LiveBoardFx diffs to glow ONE meter) ----------
  # The Next Release card is replaced wholesale on every CI upsert, so the only way the
  # board can tell which meter moved is this string. Two failure modes, one each way:
  # too STICKY and the tick shows nothing; too TWITCHY and every re-render rings a meter
  # that did nothing. Both are pinned below.

  test "[unit] the signature moves when a test finishes, and holds when nothing did" do
    running = release_meter_assembling(check_progress(%w[success in_progress in_progress]))
    ticked  = release_meter_assembling(check_progress(%w[success success in_progress]))
    again   = release_meter_assembling(check_progress(%w[success in_progress in_progress]))

    assert_not_equal release_meter_signature(running), release_meter_signature(ticked),
                     "a finished test must move the signature — it IS the whole diff"
    assert_equal release_meter_signature(running), release_meter_signature(again),
                 "and an unmoved meter must not, or every re-render glows a meter that did nothing"
  end

  test "[unit] the signature catches a second failure the fraction cannot see" do
    # Already red, and the PASSED count does not climb — so state and value both stand
    # still across a real tick. Only the marks move, which is why they are in the string.
    red    = release_meter_assembling(check_progress(%w[failure in_progress in_progress]))
    redder = release_meter_assembling(check_progress(%w[failure failure in_progress]))

    assert_equal red[:state], redder[:state], "still :failed"
    assert_equal red[:value], redder[:value], "and the fraction is blind to this tick"
    assert_not_equal release_meter_signature(red), release_meter_signature(redder),
                     "so the marks must catch it — a second failure is the tick most worth seeing"
  end

  # ---- the CARD signature (what earns a whole-card flash) ------------------------
  # The blocker this closes: branching on "no meter moved" also fires when NOTHING moved,
  # and a queued→in_progress CI delivery re-renders the card byte-identically. So the card
  # needs a positive reason of its own.

  test "[unit] the card signature holds across a byte-identical re-render" do
    rel = lane_release("mcritchie-studio")

    assert_equal release_card_signature(rel), release_card_signature(Release.find(rel.id)),
                 "a re-render with no card change must not move the signature — that is the flash-at-nothing bug"
  end

  test "[unit] the card signature moves on a new card fact and on a new member" do
    rel = lane_release("mcritchie-studio")
    before = release_card_signature(rel)

    # A QA URL appearing puts a "QA ↗" link on the card — a card-level change with no meter
    # behind it, which is exactly what the card-wide flash is FOR.
    rel.update!(qa_url: "https://qa.example.test")
    linked = release_card_signature(rel.reload)
    assert_not_equal before, linked, "a new QA link is a card-level change"

    Task.create!(title: "member turf-monster #{SecureRandom.hex(2)}", stage: "reviewed", position: 99,
                 release_slug: rel.slug, metadata: { "devops" => { "repositories" => ["turf-monster"] } })
    assert_not_equal linked, release_card_signature(rel.reload), "a member joining is a card-level change"
  end

  test "[unit] a stage advance is a METER change, not a card change" do
    rel = lane_release("mcritchie-studio")
    card_before = release_card_signature(rel)
    qa_meter = ->(r) { release_repo_lanes(r).first[:phases].find { |p| p[:key] == "qa_deploying" } }
    meter_before = release_meter_signature(qa_meter.call(rel))

    rel.stamp_stage!("qa_deploying")

    # Deliberate, and the reason the card holds still: release_meter_deploy reads the
    # release's own stage stamps, so entering QA lights the QA METER. The advance is drawn
    # BY a meter, so the meter rings and the card has no reason to flash. Putting the stage
    # in the card signature would fire both for one event.
    assert_not_equal meter_before, release_meter_signature(qa_meter.call(rel.reload)),
                     "entering QA must move the QA meter"
    assert_equal card_before, release_card_signature(rel.reload),
                 "and must NOT also move the card — one event, one effect"
  end

  test "[unit] the card signature ignores the ticking clock" do
    rel = lane_release("mcritchie-studio")
    before = release_card_signature(rel)

    # The card draws "in progress · 2h 53m" off created_at and advances it every minute,
    # client-side. Folding that in would flash the card with no visible cause — the exact
    # defect this signature exists to prevent.
    rel.update!(created_at: rel.created_at - 3.hours)
    assert_equal before, release_card_signature(rel.reload),
                 "the elapsed clock must not move the signature"
  end

  private

  # A CheckProgress from a list of GitHub conclusions ("in_progress" = still running).
  # Distinct names, because the marks sort by severity THEN name.
  def check_progress(conclusions)
    runs = conclusions.each_with_index.map do |conclusion, i|
      if conclusion == "in_progress"
        { "status" => "in_progress", "name" => "check-#{i}" }
      else
        { "status" => "completed", "conclusion" => conclusion, "name" => "check-#{i}" }
      end
    end
    Ci::CheckProgress.from_check_runs(runs, sha: "abc123")
  end

  def lane_release(*repos)
    rel = Release.open!
    repos.each_with_index do |repo, i|
      Task.create!(title: "member #{repo} #{SecureRandom.hex(2)}", stage: "reviewed", position: (i + 1) * 10,
                   release_slug: rel.slug, metadata: { "devops" => { "repositories" => [repo] } })
    end
    rel.reload
  end
end
