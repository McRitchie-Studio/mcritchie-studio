# frozen_string_literal: true

# bin/dor-check ON A TASK WITH A PR IN EVERY REPO IT NAMES.
# Standalone (no Rails — it drives the script with --file fixtures):
#   ruby -Itest test/lib/dor_check_multi_repo_pr_test.rb
#
# THE DEFECT (/tasks/dor-check-reads-one-pr, found independently by two agents on
# 2026-09-07, hours apart). `devops.pr_url` — SINGULAR — fed BOTH the PR file list and
# the CI verdict, while the plural `devops.pr_urls` register fed only the cert gate's
# repo list. On a two-repo task the shape/tier gate, the doc-only exemption, migration
# detection and the CI allow-list were therefore all measured against ONE PR, and the
# verdict read as though it covered the task.
#
# WHY IT OUTLIVED THE KNOWN LIMIT. "The gate sees only the repos a task NAMES" was
# already understood, and the standing remedy was to fix the record. This sat a rung
# below that: on /tasks/document-burn-entry-token the task named BOTH repos and
# recorded BOTH PR URLs correctly, and the gate still read one. Measured before the
# fix — DOR_CHECK_DIFF_ROOT at turf-vault and again at turf-monster returned the
# IDENTICAL three turf-vault files, because PR files outrank the git tree, so changing
# the tree changes nothing. turf-monster's only file, docs/SOLANA.md, appeared in
# neither run.
#
# EVERY TEST HERE DRIVES THE REAL GATE, through --file fixtures and the two per-repo
# injection seams, and reads its verdict back out of --json. A unit test of the folder
# would pass happily while the caller never handed it the second PR — which is the
# whole shape of the bug.
#
# THE HAPPY PATH IS THE TRAP, so it is never asserted alone. Every refusal below is
# paired with a CONTROL that differs in exactly the fact under test and PASSES, so a
# refusal can never be credited to some unrelated permanent objection. And the seams
# are read BACK from the payload (`pr_coverage[].ci`, `changed_files`) rather than
# assumed to have landed: OutboundSeams seals `gh` to a stub that exits non-zero with
# no stdout, so a seam that failed to land does not fall back to the network — it
# fails the read, which this suite can tell apart from every other state.
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class DorCheckMultiRepoPrTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  HUB = "mcritchie-studio"
  SAT = "turf-monster"
  HUB_PR = "https://github.com/McRitchie-Studio/#{HUB}/pull/11"
  SAT_PR = "https://github.com/McRitchie-Studio/#{SAT}/pull/575"

  HUB_DOC = "docs/agents/modules/gates/dor.md"
  SAT_DOC = "docs/SOLANA.md"          # the file the pre-fix gate never saw
  SAT_CODE = "app/models/entry.rb"

  # ── the harness ─────────────────────────────────────────────────────────────

  # A task that NAMES two repos and RECORDS a PR in each — the record that was already
  # correct when the gate read one of them.
  def devops(extra = {})
    { "kind" => "docs", "shape" => "docs",
      "pr_url" => HUB_PR,
      "pr_urls" => { HUB => HUB_PR, SAT => SAT_PR },
      "repositories" => [HUB, SAT],
      "acceptance" => ["Prose explains the multi-repo gate"],
      "risk_tags" => ["docs"], "test_plan" => ["[docs] prose"],
      "checks_run" => ["[docs] prose read"], "post_deploy_cmd" => "none" }.merge(extra)
  end

  # Drives the REAL gate. `files` and `ci` are per-repo maps through
  # DOR_CHECK_PR_FILES_BY_REPO / DOR_CHECK_CI_STATUS_BY_REPO, each value carrying the
  # SAME token grammar the singular seams take — so the classifier under measurement is
  # the real one, not a hand-built hash.
  def drive(files:, ci:, role: "review", devops_extra: {}, changed_files: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "multi-repo-task", "title" => "T",
                                     "metadata" => { "devops" => devops(devops_extra) }))
      seams = {
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_PR_FILES_BY_REPO" => JSON.generate(files),
        "DOR_CHECK_CI_STATUS_BY_REPO" => JSON.generate(ci),
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      }
      seams["DOR_CHECK_CHANGED_FILES"] = changed_files if changed_files
      out = IO.popen(OutboundSeams.env(seams),
                     "#{BIN} multi-repo-task --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      refute_empty out.to_s.strip, "the gate produced no JSON at all — nothing below read anything"
      [JSON.parse(out), code]
    end
  end

  # A SINGLE-repo task, for the regression guard that the ordinary path is untouched.
  def drive_single(pr_files:, ci:, role:, changed_files: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      single = devops("pr_urls" => { HUB => HUB_PR }, "repositories" => [HUB])
      File.write(path, JSON.generate("slug" => "single-repo-task", "title" => "T",
                                     "metadata" => { "devops" => single }))
      seams = {
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_PR_FILES" => pr_files, "DOR_CHECK_CI_STATUS" => ci,
        "DOR_CHECK_SUITE_EVIDENCE" => "ok"
      }
      seams["DOR_CHECK_CHANGED_FILES"] = changed_files if changed_files
      out = IO.popen(OutboundSeams.env(seams),
                     "#{BIN} single-repo-task --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      refute_empty out.to_s.strip, "the single-repo gate produced no JSON at all"
      [JSON.parse(out), code]
    end
  end

  def row_for(verdict, repo)
    Array(verdict["pr_coverage"]).find { |row| row["repo"] == repo }
  end

  def lines(verdict)
    Array(verdict["errors"]) + Array(verdict["suggestions"])
  end

  # THE GREEN TWO-REPO FIXTURE, used as the control under every refusal below. Both
  # PRs read, both green, both doc-only — the one shape this gate should advance.
  def green_both
    drive(files: { HUB => HUB_DOC, SAT => SAT_DOC }, ci: { HUB => "green", SAT => "green" })
  end

  # ── 1. the defect, closed: TWO verdicts, each naming its own repo's files ────

  def test_the_diff_is_the_union_of_every_recorded_pr
    verdict, code = green_both

    assert verdict["ready"], "the control fixture must PASS, or every refusal below proves nothing:\n" \
                             "#{lines(verdict).join("\n")}"
    assert_equal 0, code

    files = Array(verdict["changed_files"])
    assert_includes files, HUB_DOC, "the primary PR's file is missing — the gate read neither PR"
    assert_includes files, SAT_DOC,
                    "THE DEFECT. The second recorded PR's file is absent from the observed diff, so this " \
                    "verdict describes one repo while reading as though it covered the task. changed_files: " \
                    "#{files.inspect}"
  end

  def test_the_verdict_reports_one_row_per_pr_naming_that_repos_own_files
    verdict, = green_both
    rows = Array(verdict["pr_coverage"])

    assert_equal 2, rows.size, "a two-PR task must report two coverage rows, not #{rows.size}: #{rows.inspect}"

    hub = row_for(verdict, HUB)
    sat = row_for(verdict, SAT)
    refute_nil hub, "no coverage row for #{HUB}: #{rows.inspect}"
    refute_nil sat, "no coverage row for #{SAT}: #{rows.inspect}"

    assert_equal [HUB_DOC], hub["file_sample"], "#{HUB}'s row must name #{HUB}'s OWN files"
    assert_equal [SAT_DOC], sat["file_sample"], "#{SAT}'s row must name #{SAT}'s OWN files"

    # THE ROWS ARE TWO DISTINCT READS, not one read reported twice — which is what a
    # regression to the single-PR reader would look like from the union alone.
    refute_includes hub["file_sample"], SAT_DOC,
                    "#{HUB}'s row claims #{SAT}'s file: the rows are not separate reads"
    assert_equal HUB_PR, hub["pr_url"]
    assert_equal SAT_PR, sat["pr_url"]
  end

  # ── 2. THE SEAM LANDED, proven per repo (anti-vacuity) ──────────────────────

  def test_each_repo_gets_its_own_ci_verdict_not_a_shared_one
    # DIFFERENT states per repo. If the per-repo seam were ignored, both rows would
    # carry the same state and this could not tell that from a working read.
    verdict, = drive(files: { HUB => HUB_DOC, SAT => SAT_DOC },
                     ci: { HUB => "green", SAT => "pending" })

    assert_equal "green", row_for(verdict, HUB)["ci"],
                 "#{HUB}'s injected CI did not reach the gate — the per-repo seam is not on the path"
    assert_equal "pending", row_for(verdict, SAT)["ci"],
                 "#{SAT}'s injected CI did not reach the gate, or both repos shared one verdict"
  end

  # ── 3. THE MUTATION: one red PR refuses the whole verdict ───────────────────

  def test_a_red_ci_on_the_second_pr_refuses_the_verdict
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => SAT_DOC },
                          ci: { HUB => "green", SAT => "red" })

    assert_equal "red", verdict.dig("ci", "state"),
                 "the governing verdict must be the RED one, not the green PR that happens to be recorded " \
                 "first — see TaskPrSet.governing"
    refute verdict["ready"], "a RED CI on ANY of the task's PRs must refuse the verdict"
    assert_equal 1, code

    assert_equal "green", row_for(verdict, HUB)["ci"],
                 "the control half of this mutation: the OTHER PR really was green, so the refusal is the " \
                 "red one's and not a blanket objection"
  end

  # ORDER MUST NOT DECIDE IT. `pr_url` is recorded first, so a first-non-green fold
  # would pass this case and fail the one above — or the reverse. Worst-of passes both.
  def test_a_red_ci_on_the_first_pr_also_refuses
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => SAT_DOC },
                          ci: { HUB => "red", SAT => "green" })

    assert_equal "red", verdict.dig("ci", "state")
    refute verdict["ready"]
    assert_equal 1, code
  end

  # THE ALLOW-LIST PROPERTY, one level up. A state the severity table has never heard
  # of must GOVERN, not lose to a sibling's green — otherwise every state added to
  # ci_status.rb later joins the safe side silently, which is exactly how a blank
  # pr_url once reached the review gate as a pass.
  def test_a_ci_state_this_gate_has_never_heard_of_governs_over_a_green_sibling
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => SAT_DOC },
                          ci: { HUB => "green", SAT => "state:novel-state-nobody-classified" })

    assert_equal "novel-state-nobody-classified", verdict.dig("ci", "state"),
                 "an unclassified state lost to a sibling's green — the fold is a deny-list"
    refute verdict["ready"]
    assert_equal 1, code
  end

  # ── 4. THE SECOND PR'S CONTENT IS GRADED, not just counted ──────────────────

  def test_code_in_the_second_pr_refuses_the_doc_only_exemption
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => SAT_CODE },
                          ci: { HUB => "green", SAT => "green" })

    refute verdict["ready"],
           "a code file in the SECOND repo's PR was waved through as a doc-only diff — the exact false pass " \
           "this task closes:\n#{lines(verdict).join("\n")}"
    assert_equal 1, code
    assert_includes Array(verdict["changed_files"]), SAT_CODE
    assert(lines(verdict).any? { |line| line.include?(SAT_CODE) },
           "the refusal must NAME the offending file:\n#{lines(verdict).join("\n")}")
  end

  # ── 5. FAIL CLOSED, AND SAY WHICH REPO — in BOTH roles ──────────────────────

  def assert_fails_closed_naming_the_unread_repo(role)
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => "unreadable:Bad credentials" },
                          ci: { HUB => "green", SAT => "green" }, role: role)

    refute verdict["ready"],
           "#{role}: a PR the gate could not read must FAIL the verdict CLOSED, never be graded around"
    assert_equal 1, code
    assert_equal "pr_incomplete", verdict["diff_source"],
                 "#{role}: the run must say the read did not COMPLETE — 'indeterminate' would send the " \
                 "reader to a checkout that is perfectly healthy"

    named = Array(verdict["errors"]).select { |line| line.include?(SAT) }
    refute_empty named,
                 "#{role}: the refusal must NAME the repo it could not read, and it must land as an ERROR. " \
                 "A gate that grades a subset is the disease; one that grades a subset and says which is " \
                 "merely limited:\n#{lines(verdict).join("\n")}"

    # ...AND THE MACHINE-READABLE HALF. Prose in `note` is what a human reads; a monitor
    # asking "which repo failed closed here?" needs a field. This is the payload a
    # :pr_incomplete run exits through, so if coverage is missing anywhere it will be
    # missing exactly here — the refusal it exists to explain.
    rows = Array(verdict["pr_coverage"])
    assert_equal 2, rows.size, "#{role}: the fail-closed payload dropped its coverage rows: #{verdict.inspect}"
    assert_equal "ok", row_for(verdict, HUB)["read"], "#{role}: the readable PR must still report as read"
    refute_equal "ok", row_for(verdict, SAT)["read"],
                 "#{role}: the UNREADABLE PR must be marked unread in the machine-readable rows, or the " \
                 "refusal is unexplainable from the JSON alone: #{rows.inspect}"
  end

  def test_an_unreadable_pr_fails_closed_and_names_the_repo_in_the_review_role
    assert_fails_closed_naming_the_unread_repo("review")
  end

  # THE HALF THAT IS NOT INHERITED. Submit-side a single-repo unreadable read only
  # WARNS, because the builder stands in that PR's own worktree and the local view is
  # its honest near-twin. On a two-repo task the builder stands in ONE of them, so no
  # tree on the machine can stand in for the other and the same read must refuse.
  def test_an_unreadable_pr_fails_closed_and_names_the_repo_in_the_builder_role
    assert_fails_closed_naming_the_unread_repo("builder")
  end

  # THE SHAPE WHERE THE ROLE HALF ACTUALLY BITES. On an EXEMPT kind an empty diff
  # refuses on its own (the doc-only claim cannot be proven), so both roles would refuse
  # there even if the alert were filed as a suggestion. On a NON-exempt shape nothing
  # else objects: the tiers come from the shape, not the diff, so an empty observation
  # sails straight through and a suggestion refuses nothing. This is the case that
  # measures pr_read_refuses_verdict?'s both-roles rule rather than inheriting a refusal
  # from somewhere else.
  def assert_non_exempt_fails_closed(role)
    feature = { "kind" => "feature", "shape" => "backend",
                "checks_run" => ["[unit] bin/rails test test/models", "[integration] bin/rails test test/integration"],
                "test_plan" => ["[unit] models", "[integration] flows"] }
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => "unreadable:Bad credentials" },
                          ci: { HUB => "green", SAT => "green" }, role: role, devops_extra: feature)

    refute verdict["ready"],
           "#{role}: a non-exempt shape with one PR unread PASSED — the tier gate reads the shape, not the " \
           "diff, so nothing but this refusal stands between an unread repo and a green verdict:\n" \
           "#{lines(verdict).join("\n")}"
    assert_equal 1, code
    refute_empty Array(verdict["errors"]).select { |line| line.include?(SAT) },
                 "#{role}: and it must name #{SAT}:\n#{lines(verdict).join("\n")}"
  end

  def test_a_non_exempt_shape_fails_closed_in_the_review_role
    assert_non_exempt_fails_closed("review")
  end

  def test_a_non_exempt_shape_fails_closed_in_the_builder_role
    assert_non_exempt_fails_closed("builder")
  end

  # ...and its control: the same non-exempt fixture PASSES once both PRs read.
  def test_the_non_exempt_fixture_passes_when_every_pr_reads
    feature = { "kind" => "feature", "shape" => "backend",
                "checks_run" => ["[unit] bin/rails test test/models", "[integration] bin/rails test test/integration"],
                "test_plan" => ["[unit] models", "[integration] flows"] }
    verdict, code = drive(files: { HUB => HUB_DOC, SAT => SAT_DOC },
                          ci: { HUB => "green", SAT => "green" }, devops_extra: feature)

    assert verdict["ready"], "the readable twin of the non-exempt fixture must PASS:\n#{lines(verdict).join("\n")}"
    assert_equal 0, code
  end

  # THE CONTROL FOR BOTH OF THE ABOVE, spelled out: the ONLY difference from the
  # passing fixture is that one PR could not be read. Without this, the refusals above
  # are consistent with the gate refusing this fixture for any reason at all.
  def test_the_same_fixture_passes_once_that_pr_can_be_read
    verdict, code = green_both

    assert verdict["ready"], "the readable twin of the fail-closed fixture must PASS:\n#{lines(verdict).join("\n")}"
    assert_equal 0, code
    assert_equal "pr", verdict["diff_source"]
  end

  # A RECORDED URL THE GATE CANNOT PARSE is a repo whose verdict cannot be obtained —
  # a different fact from "no PR yet", and one the gate must refuse rather than skip.
  # The remedy has to name the FIELD to edit, and the primary and the register are
  # different fields.
  def test_an_unparseable_recorded_url_fails_closed_and_names_the_field
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      broken = devops("pr_urls" => { HUB => HUB_PR, SAT => "https://example.com/not-a-pr" })
      File.write(path, JSON.generate("slug" => "multi-repo-task", "title" => "T",
                                     "metadata" => { "devops" => broken }))
      out = IO.popen(OutboundSeams.env({
                       "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
                       "DOR_CHECK_PR_FILES_BY_REPO" => JSON.generate(HUB => HUB_DOC),
                       "DOR_CHECK_CI_STATUS_BY_REPO" => JSON.generate(HUB => "green", SAT => "green"),
                       "DOR_CHECK_SUITE_EVIDENCE" => "ok"
                     }),
                     "#{BIN} multi-repo-task --file #{path} --json --gate-role review 2>/dev/null", &:read)
      refute_empty out.to_s.strip, "the gate produced no JSON at all"
      verdict = JSON.parse(out)

      refute verdict["ready"], "an unparseable recorded PR URL must fail the verdict closed"
      assert_equal "pr_incomplete", verdict["diff_source"]
      remedy = Array(verdict["errors"]).find { |line| line.include?("not a GitHub pull-request URL") }
      refute_nil remedy, "the refusal must say WHY the URL could not be read:\n#{lines(verdict).join("\n")}"
      assert_includes remedy, "devops.pr_urls[#{SAT}]",
                      "...and name the FIELD to edit, so the remedy can actually be followed:\n#{remedy}"
    end
  end

  # ── 6. THE HUMAN VERDICT SAYS IT TOO, on the shape most at risk ─────────────

  # THE JSON IS NOT THE VERDICT MOST PEOPLE READ, and the EXEMPT verdicts exit early on
  # their own printer — which is exactly where the 08-08 false pass lived. A coverage
  # block only the gated path printed would be absent from every doc-only run, the runs
  # most in need of it.
  def drive_text(files:, ci:, role: "review")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "multi-repo-task", "title" => "T",
                                     "metadata" => { "devops" => devops }))
      out = IO.popen(OutboundSeams.env({
                       "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
                       "DOR_CHECK_PR_FILES_BY_REPO" => JSON.generate(files),
                       "DOR_CHECK_CI_STATUS_BY_REPO" => JSON.generate(ci),
                       "DOR_CHECK_SUITE_EVIDENCE" => "ok"
                     }),
                     "#{BIN} multi-repo-task --file #{path} --gate-role #{role} 2>&1", &:read)
      refute_empty out.to_s.strip, "the gate printed nothing at all"
      out
    end
  end

  def test_the_exempt_human_verdict_prints_a_row_per_pr
    text = drive_text(files: { HUB => HUB_DOC, SAT => SAT_DOC }, ci: { HUB => "green", SAT => "green" })

    assert_includes text, "PRs read (2):", "the exempt verdict printed no coverage block:\n#{text}"
    assert_includes text, "#{SAT} PR 575", "the block must name the second repo AND its PR number:\n#{text}"
    assert_includes text, SAT_DOC, "...and the files that PR contributed:\n#{text}"
    assert_includes text, HUB_DOC, "...and the first PR's, so both halves are visible:\n#{text}"
  end

  # ── 7. THE SINGLE-REPO PATH IS UNTOUCHED ────────────────────────────────────

  # The builder's fallback is EARNED, and it survives. A one-PR task cannot produce
  # :incomplete, so an aged App token still costs a builder a loud suggestion rather
  # than a blocked handoff — which is the trade this fix must not quietly revoke.
  def test_a_single_repo_builder_still_only_warns_on_an_unreadable_read
    verdict, = drive_single(pr_files: "unreadable:Bad credentials", ci: "green",
                            role: "builder", changed_files: HUB_DOC)

    alert = lines(verdict).find { |line| line.include?("did NOT read the PR") }
    refute_nil alert, "the single-repo unreadable alert stopped printing entirely:\n#{lines(verdict).join("\n")}"
    assert_includes Array(verdict["suggestions"]), alert,
                    "submit-side, a ONE-PR unreadable read must stay a suggestion — this fix tightened the " \
                    "multi-repo case only"
    refute_equal "pr_incomplete", verdict["diff_source"],
                 "a single-PR task must never resolve the multi-repo incomplete state"
  end

  def test_a_single_repo_task_prints_no_coverage_block
    verdict, = drive_single(pr_files: HUB_DOC, ci: "green", role: "review")

    assert_equal 1, Array(verdict["pr_coverage"]).size,
                 "one PR, one row — the human block is what is suppressed, not the record"
    assert verdict["ready"], "the ordinary one-PR verdict must be unchanged:\n#{lines(verdict).join("\n")}"
  end
end
