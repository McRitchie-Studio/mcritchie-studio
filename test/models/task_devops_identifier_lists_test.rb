require "test_helper"

# The KEY-SCOPED comma rule on devops LIST keys: an identifier list splits a joined
# entry, a prose list never does.
#
# THE SURFACE THIS COVERS IS THE RAW JSON API. `bin/task` refuses `--repo a,b` at the
# terminal (COMMA_FREE_LIST_FLAGS), and that refusal is the first and best home — only
# the CLI can name the FLAG and print a copyable corrected line. But it can only guard
# callers that go through it. Anything POSTing /api/v1/tasks directly was unguarded,
# and the value alone cannot be judged there: `["a,b"]` from --repo and `["one thing,
# then another"]` from --accept are both one-element arrays. The KEY can be judged, and
# Task.normalize_devops_metadata already branches on it. The argument for splitting
# rather than refusing lives at Task::DEVOPS_IDENTIFIER_LIST_KEYS.
#
# A NEW FILE RATHER THAN AN APPEND: test/models/task_test.rb is a frozen hotspot in
# config/test_health.yml (2023, at its ceiling), and the freeze exists to push new
# tests into new files. The one case there whose CLAIM this change narrows — array
# lists keeping their commas, now true of prose keys only — was edited in place.
class TaskDevopsIdentifierListsTest < ActiveSupport::TestCase
  TURF_PR = "https://github.com/McRitchie-Studio/turf-monster/pull/305".freeze
  HUB_PR  = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/1420".freeze

  # A realistic joined pair per identifier key, so the split is asserted against the
  # vocabulary each key's readers actually look up (Release::Conductor resolves a
  # repository; ReviewerSelector::RISK_DOMAINS and blocked_risk_tags match a tag
  # EXACTLY). Derived from the constant, so a key added to it must be given a value
  # here rather than silently skipping the assertion.
  JOINED = {
    "repositories" => ["turf-monster,mcritchie-studio", %w[turf-monster mcritchie-studio]],
    "risk_tags"    => ["auth,migration", %w[auth migration]]
  }.freeze

  # --- the identifier keys: a joined entry is split ---------------------------

  test "[unit] a joined identifier entry posted as an array is split per key" do
    assert_equal Task::DEVOPS_IDENTIFIER_LIST_KEYS.sort, JOINED.keys.sort,
                 "every guarded key needs a joined sample here, or its case never runs"

    Task::DEVOPS_IDENTIFIER_LIST_KEYS.each do |key|
      joined, split = JOINED.fetch(key)
      metadata = Task.normalize_devops_metadata(key => [joined])

      assert_equal split, metadata[key],
                   "devops.#{key} arrived from the raw API as one joined entry and stayed one"
    end
  end

  # THE CONSISTENCY ARGUMENT, asserted rather than only written in the comment. The
  # board form posts `repositories` as a STRING and that branch has always split on
  # commas, so refusing the array form would have made the same key's answer depend on
  # the JSON type of the payload. These two now converge.
  test "[unit] the array and string forms of an identifier key agree" do
    Task::DEVOPS_IDENTIFIER_LIST_KEYS.each do |key|
      joined, split = JOINED.fetch(key)

      assert_equal split, Task.normalize_devops_metadata(key => [joined])[key]
      assert_equal split, Task.normalize_devops_metadata(key => joined)[key],
                   "the board form's string branch is what the array form now matches"
    end
  end

  test "[unit] an already-correct identifier list is untouched" do
    Task::DEVOPS_IDENTIFIER_LIST_KEYS.each do |key|
      _joined, split = JOINED.fetch(key)

      assert_equal split, Task.normalize_devops_metadata(key => split)[key]
    end
  end

  # --- the prose keys: THE CONTROL. A legal comma must survive ----------------

  # 291 / 230 / 1605 board tasks carry a comma in acceptance / test_plan / checks_run
  # (360 / 309 / 5883 individual entries, measured 2026-09-16). A blanket rule would
  # shred every one of them into fragments, which is a worse defect than the one being
  # fixed. Asked over the COMPLEMENT of the guarded set, so a prose key added to
  # DEVOPS_LIST_KEYS is covered the day it lands, and a prose key wrongly added to the
  # guarded set fails HERE as well as above.
  test "[unit] a comma inside a prose list entry is never split" do
    prose = Task::DEVOPS_LIST_KEYS - Task::DEVOPS_IDENTIFIER_LIST_KEYS

    assert_equal %w[acceptance test_plan checks_run abandoned_prs fix_forward], prose,
                 "the unguarded remainder is the list this rule promises never to touch"

    prose.each do |key|
      entry = "Header stays pinned, even while scrolling"
      metadata = Task.normalize_devops_metadata(key => [entry])

      assert_equal [entry], metadata[key],
                   "devops.#{key} carries prose — splitting it would shred a real entry"
    end
  end

  # The prose control at the SIZE it fails at. One entry proves the branch; a bullet
  # list proves the fragments a blanket split would have produced are not there.
  test "[unit] a multi-comma acceptance bullet keeps every clause" do
    bullet = "The sweep promotes accepted, deploys QA, and flips members assembled"
    metadata = Task.normalize_devops_metadata("acceptance" => [bullet, "Email still works"])

    assert_equal [bullet, "Email still works"], metadata["acceptance"]
  end

  # --- the guarded set itself -------------------------------------------------

  # A typo'd entry in the constant would be INERT — the exact failure mode this rule
  # exists to repair, one layer up. Mirrors the CLI-side check in
  # test/lib/task_comma_list_flags_test.rb, which reads its constant out of bin/task.
  test "[unit] every guarded key is a real devops list key" do
    assert Task::DEVOPS_IDENTIFIER_LIST_KEYS.any?, "an empty guarded set asserts nothing"

    Task::DEVOPS_IDENTIFIER_LIST_KEYS.each do |key|
      assert_includes Task::DEVOPS_LIST_KEYS, key,
                      "#{key} is guarded as a list key but is not one — the guard never fires"
    end
  end

  # --- pr_urls: the repo KEY --------------------------------------------------

  # THE HOLE, measured 2026-09-16 before the fix: `{"pr_urls" => ["<turf url>,<hub
  # url>"]}` stored `{"turf-monster" => "<turf url>,<hub url>"}` — turf's url mangled
  # into something no reader can resolve, and the HUB'S PR LOST ENTIRELY. That is the
  # 2026-08-13 half-ship shape exactly: a repo whose PR has nowhere to live, with
  # #repos_missing_pr_url reporting turf covered by a value that is not a url.
  test "[unit] a joined list of pr urls files both repos" do
    metadata = Task.normalize_devops_metadata("pr_urls" => ["#{TURF_PR},#{HUB_PR}"])

    assert_equal({ "turf-monster" => TURF_PR, "mcritchie-studio" => HUB_PR }, metadata["pr_urls"])
  end

  # The HASH form needs no comma rule of its own, and this pins WHY so nobody adds a
  # redundant second guard: the entry is keyed by the repo its URL names, and a key
  # that disagrees already raises. A joined key can never agree with one repo.
  test "[unit] a joined pr_urls hash key still raises on the repo it disagrees with" do
    error = assert_raises(ArgumentError) do
      Task.normalize_devops_metadata("pr_urls" => { "turf-monster,mcritchie-studio" => TURF_PR })
    end

    assert_match(/turf-monster,mcritchie-studio/, error.message)
  end

  # A url whose own repo segment carries a comma named no real repo either way; after
  # the split neither fragment parses, so it is REFUSED rather than filed under a
  # comma-bearing key that nothing can look up.
  test "[unit] a pr url whose repo segment holds a comma is refused" do
    assert_raises(ArgumentError) do
      Task.normalize_devops_metadata("pr_urls" => ["https://github.com/McRitchie-Studio/a,b/pull/1"])
    end
  end
end
