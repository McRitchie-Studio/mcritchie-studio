require "test_helper"

# [component] The per-repo lanes tracker (tasks/_release_lanes + _release_phase_meter).
# Pins: one lane per member repo; Assembling draws the G3 CI as one mark per check INSIDE
# its bar, on a card that links to the run; the deploy meters are GATED by the release's
# own stage (a stray run can't light a phase it hasn't entered) and link to their run once
# reached; Confirming runs as a coarse indeterminate bar; a library shows Published + n/a
# deploy phases. Also pins what a review measured and blocked on: the mark cap, the
# name-ordering, the un-clippable overflow mark, and the card's accessible name.
class ReleaseLanesTest < ActionView::TestCase
  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
  end

  test "[component] one lane per repo; Assembling shows CI + link; deploy meters gated pending" do
    rel = lane_release("mcritchie-studio", "turf-monster")
    seed_ci("amcritchie/mcritchie-studio", "release", "CI", "mcr", 8)
    # A completed QA Deploy run exists, but the release is still at Assembling — it must NOT light QA.
    seed_deploy("amcritchie/mcritchie-studio", "QA Deploy", "completed", "success", 9001)

    render partial: "tasks/release_lanes", locals: { release: rel }

    assert_select "[data-test='release-lane']", 2
    assert_select "[data-test='release-lane'] [data-test='release-phase-meter']", 8

    hub = "[data-test='release-lane'][data-repo='mcritchie-studio']"
    assert_select "#{hub} [data-phase='assembling'][data-state='done']", 1
    assert_select "#{hub} [data-phase='assembling'] a[data-test='release-phase-link']", 1, "Assembling links to its G3 run"
    assert_select "#{hub} [data-phase='assembling'] [data-test='release-phase-checks']", 1, "and shows a check row"
    assert_select "#{hub} [data-phase='qa_deploying'][data-state='pending']", 1, "a stray run cannot light QA before the release enters it"
    assert_select "#{hub} [data-phase='qa_deploying'] a", 0, "a pending meter has no link"
    assert_select "#{hub} [data-phase='confirming'][data-state='pending']", 1
    assert_select "#{hub} [data-phase='production_deploying'][data-state='pending']", 1
  end

  test "[component] a reached QA meter runs and links to its deploy run" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deploying")
    seed_deploy("amcritchie/mcritchie-studio", "QA Deploy", "in_progress", nil, 9100,
                url: "https://github.com/amcritchie/mcritchie-studio/actions/runs/9100")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    qa = "[data-repo='mcritchie-studio'] [data-phase='qa_deploying']"
    assert_select "#{qa}[data-state='running']", 1
    assert_select "#{qa} a[data-test='release-phase-link'][href='https://github.com/amcritchie/mcritchie-studio/actions/runs/9100']", 1
  end

  test "[component] the coarse Confirming meter runs as an indeterminate lavender bar" do
    rel = lane_release("mcritchie-studio")
    rel.stamp_stage!("qa_deployed")
    rel.stamp_stage!("confirming")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    conf = "[data-repo='mcritchie-studio'] [data-phase='confirming']"
    assert_select "#{conf}[data-state='running']", 1
    assert_select "#{conf} .release-meter-indeterminate", 1, "the coarse gate animates as an indeterminate bar"
  end

  test "[component] a library lane shows Published + n/a for the deploy phases" do
    rel = lane_release("studio-engine")
    seed_ci("amcritchie/studio-engine", "main", "Engine CI", "eng", 5)

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    lib = "[data-test='release-lane'][data-repo='studio-engine'][data-kind='lib']"
    assert_select "#{lib} [data-phase='published'][data-state='done']", 1
    assert_select "#{lib} [data-phase='confirming'][data-state='na']", 1
    assert_select "#{lib} [data-phase='deploying'][data-state='na']", 1
  end

  test "[component] a pending check draws a spinner; passed/failed stay glyphs" do
    rel = lane_release("mcritchie-studio")
    # Distinct check NAMES: progress_rows keeps only the latest attempt per name, so
    # same-named rows would fold into one glyph.
    seed_ci("amcritchie/mcritchie-studio", "release", "CI", "mcr", 0)
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 2, "pass", status: "completed", conclusion: "success")
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 3, "run", status: "in_progress", conclusion: nil)
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 1, "bad", status: "completed", conclusion: "failure")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    meter = "[data-repo='mcritchie-studio'] [data-phase='assembling']"
    row = "#{meter} [data-test='release-phase-checks']"
    assert_select "#{row} svg[data-test='release-check-spinner']", 3, "one spinner per pending check"
    assert_select "#{row} svg[data-test='release-check-spinner'].animate-spin.motion-reduce\\:animate-none", 3,
                  "the spinner animates, and holds still under prefers-reduced-motion"
    assert_select "#{row} span", { text: "✓", count: 2 }, "a passed check stays a ✓ glyph"
    assert_select "#{row} span", { text: "✗", count: 1 }, "a failed check stays a ✗ glyph"
    assert_not_includes css_select(row).first.to_s, "◌", "no static pending circle survives"
  end

  test "[component] the marks ride INSIDE the bar, and the whole card is the link" do
    rel = lane_release("mcritchie-studio")
    seed_ci("amcritchie/mcritchie-studio", "release", "CI", "mcr", 0)
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 2, "pass", status: "completed", conclusion: "success")
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 1, "run", status: "in_progress", conclusion: nil)

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    meter = "[data-repo='mcritchie-studio'] [data-phase='assembling']"
    assert_select "#{meter} a[data-test='release-phase-link'] [data-test='release-phase-checks']", 1,
                  "the whole card links to the run, with the marks inside it"
    assert_select "#{meter} [data-test='release-phase-bar'] [data-test='release-phase-checks']", 1,
                  "the marks sit inside the BAR itself, not in a row under it"
    assert_select "#{meter} [data-test='release-phase-value']", 0,
                  "the fraction chip is gone — the marks carry the count"
    assert_not_includes css_select(meter).first.text, "2 / 3", "no fraction is DRAWN (it survives only as the hover title)"
    assert_includes css_select("#{meter} a").first["title"], "2 / 3", "the fraction stays available on hover"
    assert_equal "Assembling — 2 of 3 checks passed", css_select("#{meter} a").first["aria-label"],
                 "a link is named by its subtree, so the summary must be spelled out — glyph soup is not a name"
    marks_row = "#{meter} [data-test='release-phase-checks']"
    assert_equal "true", css_select(marks_row).first["aria-hidden"],
                 "and the decorative marks stay out of the a11y tree"
    assert_select "#{marks_row} [title]", 0, "no per-glyph title — it would shadow the card's own tooltip"

    # A phase with no per-check marks still says where it stands, inside the same bar.
    unlinked = "[data-repo='mcritchie-studio'] [data-phase='confirming']"
    assert_select "#{unlinked} [data-test='release-phase-value']", 1
    assert_equal "img", css_select("#{unlinked} > div").first["role"],
                 "an unlinked card needs role=img, or its aria-label is dropped on the floor"
  end

  test "[component] marks are capped, ordered by name, and the overflow mark survives the clip" do
    rel = lane_release("mcritchie-studio")
    seed_ci("amcritchie/mcritchie-studio", "release", "CI", "mcr", 0)
    # 12 checks against a cap of 8 — and seeded so heap order is NOT name order.
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 9, "zz", status: "completed", conclusion: "success")
    seed_checks("amcritchie/mcritchie-studio", "release", "CI", "mcr", 3, "aa", status: "completed", conclusion: "failure")

    render partial: "tasks/release_lanes", locals: { release: rel.reload }

    meter = "[data-repo='mcritchie-studio'] [data-phase='assembling']"
    row = "#{meter} [data-test='release-phase-checks']"
    assert_select "#{row} > *", ApplicationHelper::RELEASE_METER_MARK_CAP,
                  "the row never draws more marks than fit the bar"
    assert_select "#{meter} [data-test='release-phase-overflow']", 1, "an outgrown suite says so"
    assert_select "#{row} [data-test='release-phase-overflow']", 0,
                  "the … sits OUTSIDE the clipping row — the one glyph that must never be clipped"
    assert_select "#{row} span[class*='shrink-0']", 8, "every glyph is shrink-0, or marks overlap before they clip"

    # Name order, not heap order: the three aa-* failures sort ahead of the zz-* passes, so
    # the capped row is deterministic across re-renders (the card redraws on every upsert).
    assert_equal "✗✗✗✓✓✓✓✓", css_select(row).first.text.gsub(/\s+/, ""),
                 "marks are ordered by check name, so a running suite does not reshuffle"
  end

  private

  def lane_release(*repos)
    rel = Release.open!
    repos.each_with_index do |repo, i|
      Task.create!(title: "member #{repo} #{SecureRandom.hex(2)}", stage: "reviewed", position: (i + 1) * 10,
                   release_slug: rel.slug, metadata: { "devops" => { "repositories" => [repo] } })
    end
    rel.reload
  end

  def seed_ci(nwo, branch, workflow, sha, passed)
    GithubWorkflowRun.create!(repo: nwo, workflow_name: workflow, run_id: SecureRandom.random_number(10**12),
                              status: "in_progress", head_branch: branch, head_sha: sha, run_started_at: Time.current,
                              html_url: "https://github.com/#{nwo}/actions/runs/1")
    passed.times do
      CiCheckJob.create!(repo: nwo, job_id: SecureRandom.random_number(10**12), head_sha: sha, head_branch: branch,
                         workflow_name: workflow, status: "completed", conclusion: "success", name: "check")
    end
  end

  # Extra checks on the SAME run, in any state (the pending/failed rows seed_ci never
  # makes), each with its own NAME so none folds into another attempt of the same check.
  def seed_checks(nwo, branch, workflow, sha, count, name_prefix, status:, conclusion:)
    count.times do |i|
      CiCheckJob.create!(repo: nwo, job_id: SecureRandom.random_number(10**12), head_sha: sha, head_branch: branch,
                         workflow_name: workflow, status: status, conclusion: conclusion, name: "#{name_prefix}-#{i}")
    end
  end

  def seed_deploy(nwo, workflow, status, conclusion, rid, url: nil)
    GithubWorkflowRun.create!(repo: nwo, workflow_name: workflow, run_id: rid, status: status, conclusion: conclusion,
                              head_branch: "main", head_sha: "d#{rid}", run_started_at: Time.current,
                              html_url: url || "https://github.com/#{nwo}/actions/runs/#{rid}")
  end
end
