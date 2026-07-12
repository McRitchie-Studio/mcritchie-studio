require "test_helper"

# The private checkout a gate suite runs in — pure path/name helpers.
# See Release::GateWorkspace for why the gate may not run on the shared primary.
class Release::GateWorkspaceTest < ActiveSupport::TestCase
  W = Release::GateWorkspace

  test "[unit] path is a private worktree under the repo's own .worktrees" do
    assert_equal "/Users/x/projects/mcritchie-studio/.worktrees/_gate",
                 W.path("/Users/x/projects/mcritchie-studio")
  end

  test "[unit] the gate test DB is NEVER the primary's shared test DB" do
    # The shared `mcritchie_studio_test` is what a concurrent suite (an agent
    # worktree, a hand-run `bin/rails test`) writes to. Sharing it with the gate
    # is what made failure counts vary 0 -> 8 -> 16 across seeds on ONE SHA.
    assert_equal "mcritchie_studio_gate_test", W.test_database_name("mcritchie-studio")
    assert_not_equal "mcritchie_studio_test", W.test_database_name("mcritchie-studio")
  end

  test "[unit] the gate test DB name is a legal postgres identifier (dashes folded)" do
    assert_equal "turf_monster_gate_test", W.test_database_name("turf-monster")
  end

  test "[unit] test_database_url is a local-socket URL for that private DB" do
    assert_equal "postgres:///turf_monster_gate_test", W.test_database_url("turf-monster")
  end

  test "[unit] each repo gets its OWN gate DB (no cross-repo collision)" do
    urls = %w[mcritchie-studio turf-monster rolio].map { |r| W.test_database_url(r) }

    assert_equal urls.uniq, urls
  end
end
