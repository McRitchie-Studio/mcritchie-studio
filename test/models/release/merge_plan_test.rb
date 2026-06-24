require "test_helper"

# Pure decision logic for the `bin/release merge` overlap planner. No git/gh/
# network here — same IO-free contract as ShipSequence/GemfileRepin, so it's
# trivially unit-tested and the shell stays thin.
class Release::MergePlanTest < ActiveSupport::TestCase
  M = Release::MergePlan

  def pr(slug, files, repo: "mcritchie-studio")
    { "slug" => slug, "repo" => repo, "files" => files }
  end

  # --- overlaps: same-repo pairs that share files --------------------------

  test "overlaps reports the shared files for a same-repo pair, sorted" do
    plan = M.compute([
      pr("a", ["app/models/task.rb", "docs/x.md", "a-only.rb"]),
      pr("b", ["docs/x.md", "app/models/task.rb", "b-only.rb"])
    ])
    assert_equal 1, plan["overlaps"].size
    o = plan["overlaps"].first
    assert_equal "a", o["a"]
    assert_equal "b", o["b"]
    assert_equal ["app/models/task.rb", "docs/x.md"], o["files"], "shared files are sorted"
  end

  test "overlaps is empty when no two PRs share a file" do
    plan = M.compute([pr("a", ["one.rb"]), pr("b", ["two.rb"]), pr("c", ["three.rb"])])
    assert_empty plan["overlaps"]
    assert_empty plan["rebase"], "no shared files → nothing needs a rebase"
  end

  test "overlaps NEVER pairs PRs in different repos even with an identical path" do
    # turf-monster and mcritchie-studio both have app/models/task.rb, but they are
    # different working trees — a same-path collision across repos is not a real
    # conflict, so it must not be reported.
    plan = M.compute([
      pr("studio", ["app/models/task.rb"], repo: "mcritchie-studio"),
      pr("turf", ["app/models/task.rb"], repo: "turf-monster")
    ])
    assert_empty plan["overlaps"], "cross-repo same-path files are not an overlap"
    assert_empty plan["rebase"]
  end

  test "overlaps lists each colliding pair once across three PRs" do
    plan = M.compute([
      pr("a", ["shared.rb"]),
      pr("b", ["shared.rb"]),
      pr("c", ["shared.rb"])
    ])
    pairs = plan["overlaps"].map { |o| [o["a"], o["b"]] }
    assert_equal [%w[a b], %w[a c], %w[b c]], pairs, "every colliding pair, once, in order"
  end

  # --- suggested_order: smallest-footprint first, stable -------------------

  test "suggested_order merges the smallest-footprint PR first" do
    plan = M.compute([
      pr("big", %w[1 2 3]),
      pr("small", %w[x]),
      pr("medium", %w[a b])
    ])
    assert_equal %w[small medium big], plan["suggested_order"]
  end

  test "suggested_order is stable for equal footprints (keeps given order)" do
    plan = M.compute([pr("a", %w[1]), pr("b", %w[2]), pr("c", %w[3])])
    assert_equal %w[a b c], plan["suggested_order"], "ties keep the given order"
  end

  # --- rebase: who collides with an earlier-merged same-repo PR ------------

  test "rebase flags the LATER PR that shares a file with an earlier one" do
    plan = M.compute([
      pr("first", ["app/models/task.rb"]),
      pr("second", ["app/models/task.rb", "other.rb"])
    ])
    assert_equal ["second"], plan["rebase"], "the first to touch a file is never flagged"
  end

  test "rebase computes against the GIVEN order, not the suggested order" do
    # Given order: big (touches shared) then small (also touches shared). Even
    # though suggested_order would merge small first, the rebase prediction
    # reflects what ACTUALLY runs (the given order) → small rebases.
    plan = M.compute([
      pr("big", ["shared.rb", "x.rb", "y.rb"]),
      pr("small", ["shared.rb"])
    ])
    assert_equal ["small"], plan["rebase"], "rebase reflects the given merge order"
    assert_equal %w[small big], plan["suggested_order"], "suggested merges the smaller PR first"
  end

  test "rebase only chains within a repo" do
    plan = M.compute([
      pr("studio-a", ["shared.rb"], repo: "mcritchie-studio"),
      pr("turf-a", ["shared.rb"], repo: "turf-monster"),
      pr("studio-b", ["shared.rb"], repo: "mcritchie-studio")
    ])
    assert_equal ["studio-b"], plan["rebase"], "only the second mcritchie-studio PR rebases"
  end

  # --- normalization / robustness ------------------------------------------

  test "normalize de-dupes and strips blank file paths" do
    plan = M.compute([
      pr("a", ["dup.rb", "dup.rb", "", "real.rb"]),
      pr("b", ["dup.rb"])
    ])
    assert_equal [["dup.rb"]], plan["overlaps"].map { |o| o["files"] }
  end

  test "compute tolerates an empty batch and a single PR" do
    assert_equal({ "overlaps" => [], "suggested_order" => [], "rebase" => [] }, M.compute([]))

    one = M.compute([pr("solo", ["a.rb"])])
    assert_empty one["overlaps"]
    assert_equal ["solo"], one["suggested_order"]
    assert_empty one["rebase"]
  end

  test "compute accepts symbol-keyed PR entries too" do
    plan = M.compute([
      { slug: "a", repo: "mcritchie-studio", files: ["shared.rb"] },
      { slug: "b", repo: "mcritchie-studio", files: ["shared.rb"] }
    ])
    assert_equal [%w[a b]], plan["overlaps"].map { |o| [o["a"], o["b"]] }
  end
end
