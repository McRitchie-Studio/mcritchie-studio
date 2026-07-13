require "test_helper"
require "open3"

# The private checkout a gate suite runs in — pure path/name helpers, the
# adapter-aware DB URL, and the PRIVACY INVARIANT.
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

  test "[unit] each repo gets its OWN gate DB (no cross-repo collision)" do
    urls = %w[mcritchie-studio turf-monster rolio].map { |r| W.test_database_url(r) }

    assert_equal urls.uniq, urls
  end

  # --- adapter-aware URL: a SQLite app must NOT be handed a postgres URL -------

  test "[unit] adapter reads the app's OWN database.yml, ERB and all" do
    # The real files: the hub/turf are postgres; rolio is SQLite. Read from the
    # app's truth, not a registry column that can drift.
    assert_equal "postgresql", W.adapter(Rails.root.to_s)
  end

  test "[unit] database_url_for returns the gate DB for a postgres app" do
    Dir.mktmpdir do |dir|
      write_database_yml(dir, "postgresql", "turf_monster_test")

      assert_equal "postgres:///turf_monster_gate_test", W.database_url_for("turf-monster", dir)
    end
  end

  test "[unit] database_url_for returns NIL for a SQLite app (rolio)" do
    # rolio's test DB is storage/test.sqlite3 — a FILE inside the gate worktree,
    # so it is already private and needs no override. Handing it a `postgres:///`
    # URL (as the first cut of this model did) is a live trap the moment it lands.
    Dir.mktmpdir do |dir|
      write_database_yml(dir, "sqlite3", "storage/test.sqlite3")

      assert_nil W.database_url_for("rolio", dir)
    end
  end

  test "[unit] database_url_for degrades to nil on an unreadable database.yml" do
    Dir.mktmpdir { |dir| assert_nil W.database_url_for("ghost", dir) }
  end

  # --- private_db?: the INVARIANT the gate refuses to run without --------------
  #
  # The DB name STRING proves nothing — it is what the gate INTENDS. private_db?
  # judges what the booted app ACTUALLY connected to.

  test "[unit] private_db? accepts the gate's own DB" do
    assert W.private_db?(resolved: "turf_monster_gate_test", repo: "turf-monster", workspace: "/w")
  end

  test "[unit] private_db? REJECTS the shared primary test DB" do
    # THE BUG this closes: TEST_DATABASE_URL is a hand-rolled seam that
    # turf-monster's database.yml never reads, so the overlay was INERT and the
    # gate resolved `turf_monster_test` — the SHARED DB — which the gate's own
    # db:test:prepare would then have PURGED.
    assert_not W.private_db?(resolved: "turf_monster_test", repo: "turf-monster", workspace: "/w"),
               "a shared test DB must be refused, never silently stomped"
  end

  test "[unit] private_db? accepts a SQLite file INSIDE the workspace" do
    assert W.private_db?(resolved: "storage/test.sqlite3", repo: "rolio", workspace: "/w"),
           "a file in the gate worktree is private by construction — nobody else knows the tree exists"
  end

  test "[unit] private_db? REJECTS a SQLite file OUTSIDE the workspace" do
    assert_not W.private_db?(resolved: "/elsewhere/storage/test.sqlite3", repo: "rolio", workspace: "/w")
  end

  test "[unit] private_db? does not mistake a bare DB NAME for a path inside the workspace" do
    # File.absolute_path("turf_monster_test", "/w") == "/w/turf_monster_test",
    # which is "inside" the workspace — so a naive path check would wave the
    # SHARED postgres DB straight through. Only file-backed names are path-checked.
    assert_not W.private_db?(resolved: "turf_monster_test", repo: "mcritchie-studio", workspace: "/w")
  end

  test "[unit] private_db? rejects a blank resolution (never assume)" do
    assert_not W.private_db?(resolved: "", repo: "rolio", workspace: "/w")
    assert_not W.private_db?(resolved: nil, repo: "rolio", workspace: "/w")
  end

  # --- REGRESSION (boots the app): the guarantee holds for a REAL app ----------
  #
  # Avi's review: the old test asserted the DB NAME STRING and never asserted that
  # any app HONORS the var — "a green test guarding a false guarantee". These boot
  # Rails under the gate's real overlay and ask the CONNECTION what it resolved to.

  test "[integration] an app booted under the gate env RESOLVES to the private gate DB" do
    assert_equal W.test_database_name("mcritchie-studio"), boot_and_resolve(gate_overlay)
  end

  test "[integration] the booted app's resolved DB satisfies the privacy invariant" do
    # The same check bin/release's assert_private_gate_db! performs before it lets
    # a suite (or a PURGING db:test:prepare) touch anything.
    resolved = boot_and_resolve(gate_overlay)

    assert W.private_db?(resolved: resolved, repo: "mcritchie-studio", workspace: Rails.root.to_s)
    assert_not_equal "mcritchie_studio_test", resolved, "never the SHARED primary test DB"
  end

  # WHERE THE turf-monster CASE IS COVERED, and why not here.
  #
  # The blocked bug was turf's: `TEST_DATABASE_URL` is a HAND-ROLLED seam that only
  # works where config/database.yml renders `url: <%= ENV["TEST_DATABASE_URL"] %>`.
  # The hub does; turf has a bare `database: turf_monster_test`, so the overlay was
  # INERT there and the gate would have run — and db:test:prepare-PURGED — the
  # SHARED DB. Proven by hand: under the old overlay turf boots to
  # `turf_monster_test`; under the new one (DATABASE_URL, a Rails builtin honoured
  # with no per-app wiring) it boots to `turf_monster_gate_test`.
  #
  # It is deliberately NOT modelled by booting the hub with the seam stripped: this
  # repo's *worktrees* carry a `.env.test.local` that dotenv loads, which sets
  # TEST_DATABASE_URL and beats DATABASE_URL through that same `url:` — so such a
  # test would pass on CI and fail in a worktree. An env-coupled test that reads
  # differently depending on who runs it is the precise failure this whole PR
  # exists to kill; adding one to prove the fix would be a joke at our own expense.
  # (bin/release removes any .env.test.local from the gate workspace for the same
  # reason.) The turf case is covered where it can be checked deterministically:
  #   * the overlay sets DATABASE_URL at all — Release::GateEnvTest.
  #   * private_db? REJECTS a bare `<app>_test` — above.
  #   * the gate ABORTS, before db:test:prepare, when the booted app resolves a
  #     shared DB — ReleaseCliTest (assert_private_gate_db!). That abort is the
  #     guarantee; everything else is belt.

  private

  def gate_overlay
    Release::GateEnv.env(ruby_bin_dir: "", test_database_url: W.test_database_url("mcritchie-studio"))
  end

  # Boot Rails for real and read back the database it ACTUALLY connected to.
  # capture3 (stdout only): the child re-initializes bundler and warns on stderr.
  def boot_and_resolve(overlay)
    probe = 'print "GATEDB=#{ActiveRecord::Base.connection_db_config.database}"'
    out, = Open3.capture3(overlay, "bin/rails", "runner", probe, chdir: Rails.root.to_s)
    out[/GATEDB=(.*)$/, 1].to_s.strip
  end

  def write_database_yml(dir, adapter, database)
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "config", "database.yml"), <<~YML)
      default: &default
        adapter: #{adapter}
        pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

      test:
        <<: *default
        database: #{database}
    YML
  end
  # --- the SHIP role: the deploy's own checkout ------------------------------
  #
  # Same primitive, second role. The ship needs a tree for exactly two things (the
  # re-pin commit and a repo_script satellite's own bin/deploy) and it must not
  # borrow the gate's: a concurrent conductor's G3 suite may be live in that one, and
  # sharing the tree or the DB would put a production deploy and a gate suite in each
  # other's way — the very coupling the isolated workspace exists to remove.

  test "[unit] the ship role is a DIFFERENT worktree from the gate's" do
    assert_equal "/Users/x/projects/turf-monster/.worktrees/_ship",
                 W.path("/Users/x/projects/turf-monster", role: "ship")
    assert_not_equal W.path("/Users/x/projects/turf-monster", role: "gate"),
                     W.path("/Users/x/projects/turf-monster", role: "ship")
  end

  test "[unit] the ship role has its OWN test DB — never the gate's, never the primary's" do
    assert_equal "turf_monster_ship_test", W.test_database_name("turf-monster", role: "ship")
    assert_equal "postgres:///turf_monster_ship_test", W.test_database_url("turf-monster", role: "ship")
    assert_not_equal W.test_database_name("turf-monster", role: "gate"),
                     W.test_database_name("turf-monster", role: "ship")
  end

  test "[unit] a ship suite REFUSES the gate's DB — a concurrent gate may be mid-run in it" do
    # turf's bin/deploy runs `bin/rails test` inside the ship workspace, and
    # db:test:prepare PURGES. Qualifying on the gate's DB would let a prod deploy
    # destroy a live G3 suite's data (and vice versa).
    assert_not W.private_db?(resolved: "turf_monster_gate_test", repo: "turf-monster",
                             workspace: "/w", role: "ship")
    assert W.private_db?(resolved: "turf_monster_ship_test", repo: "turf-monster",
                         workspace: "/w", role: "ship")
  end

  test "[unit] neither role EVER qualifies the shared primary test DB" do
    %w[gate ship].each do |role|
      assert_not W.private_db?(resolved: "turf_monster_test", repo: "turf-monster",
                               workspace: "/w", role: role),
                 "#{role}: the shared primary test DB is never private"
    end
  end

  test "[unit] an unknown role raises instead of minting an unlocked third workspace" do
    # A typo'd role would otherwise silently get its own dir + DB that no lock covers.
    assert_raises(ArgumentError) { W.path("/repo", role: "shipp") }
    assert_raises(ArgumentError) { W.test_database_name("turf-monster", role: "") }
  end

  test "[unit] the default role stays `gate` — every existing caller is unchanged" do
    assert_equal "/repo/.worktrees/_gate", W.path("/repo")
    assert_equal "turf_monster_gate_test", W.test_database_name("turf-monster")
  end
end
