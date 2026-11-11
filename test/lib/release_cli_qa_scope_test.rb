# frozen_string_literal: true

# QA only what the release carries (task release-sub-hour-pipeline): prepare skips the
# QA deploy of an app whose origin/release tree is the tree production's origin/main
# already runs. Run directly:
#   ruby -Itest test/lib/release_cli_qa_scope_test.rb

require_relative "release_cli_harness"

class ReleaseCliQaScopeTest < ReleaseCliHarness
  def carries(dir, release_tree:, main_tree:, repo: "voicebox", ok: true, members: [])
    setup = %(def repo_path(_r) = #{dir.inspect}\n) +
            %(def sh(*a, **_k)\n) +
            %(  return [#{release_tree.inspect}, #{ok}] if a.last == "origin/release^{tree}"\n) +
            %(  return [#{main_tree.inspect}, #{ok}] if a.last == "origin/main^{tree}"\n) +
            %(  ["", false]\nend\n)
    run_cli(["--yes"], setup: setup, call: %(print release_carries_change?({ "repo" => #{repo.inspect}, "members" => #{members.inspect} }).inspect))
  end

  def test_an_app_whose_release_tree_is_production_carries_nothing
    Dir.mktmpdir do |dir|
      assert_equal "false", carries(dir, release_tree: "T1", main_tree: "T1")
    end
  end

  def test_a_changed_tree_carries_a_change
    Dir.mktmpdir do |dir|
      assert_equal "true", carries(dir, release_tree: "T2", main_tree: "T1")
    end
  end

  def test_every_doubt_answers_carries
    Dir.mktmpdir do |dir|
      assert_equal "true", carries(dir, release_tree: "T1", main_tree: "T1", ok: false), "a git fault QA's it"
      assert_equal "true", carries(dir, release_tree: "", main_tree: ""), "an unresolved tree QA's it"
      assert_equal "true", carries(dir, release_tree: "T1", main_tree: "T1", members: [{ "slug" => "t" }]),
                   "a group with a member task is carried by definition"
      assert_equal "true", carries(dir, release_tree: "T1", main_tree: "T1", repo: "turf-monster"),
                   "a Turf repo keeps its deploy: the devnet gauntlet binds its SHA"
    end
    assert_equal "true", carries("/no/such/dir", release_tree: "T1", main_tree: "T1"), "no checkout QA's it"
  end

  def test_a_dry_run_always_carries
    out = run_cli(["--dry-run"], call: %(print release_carries_change?({ "repo" => "voicebox" }).inspect))
    assert_equal "true", out
  end
end
