# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# [integration] The abandonment receipt END TO END — written by OpenPrGuard, read
# back by bin/task's own functions, driven through the REAL script.
#
# WHY THIS TIER EXISTS AT ALL, given lib/open_pr_guard_test.rb already covers the
# predicate: the defect this task fixes did not live in the guard. It lived in
# bin/task, in the ONE LINE that read the receipt back —
# `recorded.any? { |entry| entry.include?(ref[:url]) }` — and a unit test of a
# predicate bin/task did not call would have passed over it forever. So these drive
# `archived_pr_index` and `print_task_verbose` themselves, as `bin/task orphan-prs`
# and `bin/task show --verbose` call them.
#
# WHY IT IS SAFE TO LOAD THE REAL SCRIPT. bin/task dispatches at load
# (`cmd = ARGV.shift || "help"`), so the subprocess pins ARGV to empty: the `help`
# arm reads the file's own comment header, writes it to STDERR, and exits 0, which
# the script rescues. Nothing else runs. Both functions under test are then pure
# over the hash they are handed — no board read, no `gh`, no write, no network —
# which is what makes this affordable at all. config/test_health.yml records what
# the careless version of this costs: two under-stubbed tests once ran
# bin/clean-artifacts and bin/archive-docs for real against a developer's machine.
#
# THE FIXTURE IS A LIVE RECORD, not a shape invented here. It is
# `bin/task show move-web3-modals-to-solana --json` on 2026-09-02 — the task that
# stranded studio-engine #245 and caused this whole family of work — trimmed to the
# keys these two functions read, with its `pr_url` pointed at the COLLIDING
# neighbour. The last change is the only invention, and the guard's own docblock
# names that shape as one that really occurs: "a task whose singular names the
# MERGED repo while the map holds the OPEN one". A fixture that omits what the API
# really sends is how the previous cut of this family certified green against a gate
# that refused 31 of 34 real tasks.
class OpenPrReceiptVisibilityTest < ActionDispatch::IntegrationTest
  ENGINE_245 = "https://github.com/McRitchie-Studio/studio-engine/pull/245"
  ENGINE_24  = "https://github.com/McRitchie-Studio/studio-engine/pull/24"
  SOLANA_9   = "https://github.com/McRitchie-Studio/solana-studio/pull/9"
  RECEIPT_245 = "#{ENGINE_245} open abandoned-at-archive 2026-09-02T14:00:00Z by carl"

  # The live record's devops, trimmed to what these functions touch. Every key here
  # is one the board actually returned for this task.
  def devops(overrides = {})
    {
      "kind" => "feature", "shape" => "onchain-vertical", "branch" => "feat/move-web3-modals-to-solana",
      "mascot" => "eevee", "built_by" => "jasper", "builders" => ["jasper"],
      "repositories" => %w[studio-engine solana-studio], "risk_tags" => ["web3"],
      "acceptance" => ["Solana sign-in rides an auth credential slot"],
      "test_plan" => [], "checks_run" => [], "worktree_slug" => "move-web3-modals-to-solana",
      "pr_url" => ENGINE_245,
      "pr_urls" => { "solana-studio" => SOLANA_9, "studio-engine" => ENGINE_245 }
    }.merge(overrides)
  end

  def task(slug: "move-web3-modals-to-solana", stage: "archived", **overrides)
    { "slug" => slug, "stage" => stage, "title" => "Move Web3 Modals To Solana",
      "metadata" => { "devops" => devops(overrides) } }
  end

  # Load the real bin/task in a subprocess, hand it TASK, and run `snippet` against
  # its functions. Whatever the snippet puts on STDOUT comes back; the script's own
  # help banner goes to STDERR and is discarded.
  #
  # THE PAYLOAD CROSSES AS JSON AND IS PARSED ON THE FAR SIDE — never interpolated
  # as a Ruby literal. `to_json` emits `{"slug": "x"}`, which Ruby re-reads as a
  # SYMBOL key, so an interpolated fixture arrives with every key symbolized and
  # `task["slug"]` reads nil. That silently hands the function an empty-looking task
  # and the test then measures nothing. Caught here by running these against the
  # unfixed code and reading WHY they failed rather than merely that they did.
  def in_cli(snippet, payload)
    script = <<~RUBY
      ARGV.replace([])
      begin
        load #{Rails.root.join("bin", "task").to_s.inspect}
      rescue SystemExit
        nil
      end
      TASK = JSON.parse(#{payload.to_json.dump})
      #{snippet}
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: Rails.root.to_s)
    assert_predicate status, :success?, "driving bin/task failed: #{err}"
    out
  end

  def index_for(task_hash)
    out = in_cli(<<~RUBY, task_hash)
      index = archived_pr_index([TASK])
      puts JSON.generate(index.transform_values { |v| { slug: v[:slug], deliberate: v[:deliberate] } })
    RUBY
    JSON.parse(out, symbolize_names: true)
  end

  # ── the alarm must not go quiet about a real orphan ──────────────────────────

  # THE WHOLE POINT. One task names studio-engine #245 AND #24; only #245 was
  # abandoned on purpose. Under the substring reader, the receipt for #245 CONTAINS
  # #24's url, so `bin/task orphan-prs` reported #24 as "abandoned on purpose",
  # suppressed its `decide:` remediation line, and sorted it to the bottom. A live,
  # forgotten PR reading as a settled decision is the alarm failing silently — the
  # exact harm the parent task shipped to close.
  test "a receipt for #245 does not mark the neighbouring #24 as deliberate" do
    index = index_for(task("pr_url" => ENGINE_24, "abandoned_prs" => [RECEIPT_245]))

    assert index.key?(:"McRitchie-Studio/studio-engine#24"), "#24 must be in the index at all"
    refute index[:"McRitchie-Studio/studio-engine#24"][:deliberate],
           "nobody abandoned #24; reporting it as decided is how the orphan goes unseen"
  end

  test "the receipt still marks the PR it was actually written for" do
    index = index_for(task("pr_url" => ENGINE_24, "abandoned_prs" => [RECEIPT_245]))

    assert index[:"McRitchie-Studio/studio-engine#245"][:deliberate],
           "anchoring must not cost the receipt its job"
  end

  # The control on the fixture itself: the collision it is built to expose is really
  # present. Without this, the refutation above could pass merely because the two
  # urls never overlapped — a fixture that cannot express the bug agrees with the
  # defect and the fix alike.
  test "the fixture really does contain the colliding substring" do
    assert_includes RECEIPT_245, ENGINE_24,
                    "the recorded receipt must literally contain #24's url, or these tests " \
                    "prove nothing about anchoring"
  end

  test "a task with no receipt reports every PR it names as orphaned" do
    index = index_for(task)

    refute index[:"McRitchie-Studio/studio-engine#245"][:deliberate]
    refute index[:"McRitchie-Studio/solana-studio#9"][:deliberate],
           "the map's PR is indexed too — a multi-repo task records its second repo there"
  end

  # ── the receipt is visible to a human ────────────────────────────────────────

  # Its stated purpose is that a LATER READER knows the PR was dropped on purpose.
  # Before this line, the readers that showed it were raw JSON and `orphan-prs` —
  # and `orphan-prs` lists a PR only while it is still OPEN, so the moment the
  # abandoned PR closed, the receipt survived only somewhere no default tool prints.
  test "bin/task show --verbose renders the abandonment receipt" do
    out = in_cli("print_task_verbose(TASK)", task("abandoned_prs" => [RECEIPT_245]))

    assert_includes out, "abandoned_prs:"
    assert_includes out, RECEIPT_245, "the whole entry — which PR, what state, when, and by whom"
  end

  # Unconditional, "-" when empty, for print_column_fields' reason: this is where an
  # operator confirms what `--force` just recorded, and a line that vanishes makes
  # "recorded nothing" indistinguishable from "this CLI cannot show it".
  test "the receipt line is printed even when there is nothing to report" do
    assert_includes in_cli("print_task_verbose(TASK)", task), "abandoned_prs: -"
  end

  # THE OTHER DEFAULT READER. `bin/task orphan-prs` lists a PR only while it is
  # still OPEN, so once an abandoned PR closes, this page and `show --verbose` are
  # the only places the decision survives outside raw JSON.
  test "the task page renders the abandonment receipt" do
    record = tasks(:done_task)
    record.update!(metadata: record.metadata.merge("devops" => { "abandoned_prs" => [RECEIPT_245] }))

    get task_path(record)

    assert_response :success
    assert_select "li", text: RECEIPT_245
  end

  # Present only when there IS a decision to report — this page, unlike the CLI
  # line, is not where anybody confirms a write, so an empty card would be noise on
  # every task on the board.
  test "the task page shows no receipt card when nothing was abandoned" do
    get task_path(tasks(:done_task))

    assert_response :success
    assert_select "p", text: "Abandoned PRs", count: 0
  end
end
