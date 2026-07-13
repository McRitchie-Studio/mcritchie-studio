require "test_helper"
require "shellwords"

class Release::ReposTest < ActiveSupport::TestCase
  test "classifies registered gems as :gem" do
    assert_equal :gem, Release::Repos.kind("studio-engine")
    assert_equal :gem, Release::Repos.kind("solana-studio")
    assert Release::Repos.gem?("studio-engine")
    assert Release::Repos.gem?("solana-studio")
  end

  test "classifies registered apps as :app" do
    assert_equal :app, Release::Repos.kind("mcritchie-studio")
    assert_equal :app, Release::Repos.kind("turf-monster")
    assert_equal :app, Release::Repos.kind("rolio")
    assert Release::Repos.app?("turf-monster")
    assert Release::Repos.app?("rolio")
    assert_not Release::Repos.gem?("turf-monster")
  end

  test "classifies anything outside the registry as :unknown" do
    assert_equal :unknown, Release::Repos.kind("not-a-real-repo")
    assert_equal :unknown, Release::Repos.kind(nil)
    assert_equal :unknown, Release::Repos.kind("")
    assert_not Release::Repos.gem?("not-a-real-repo")
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "gem_repos and app_repos read the registry" do
    assert_includes Release::Repos.gem_repos, "studio-engine"
    assert_includes Release::Repos.gem_repos, "solana-studio"
    assert_includes Release::Repos.app_repos, "mcritchie-studio"
    assert_not_includes Release::Repos.gem_repos, "mcritchie-studio"
  end

  test "gem_meta returns the gem's publish metadata" do
    meta = Release::Repos.gem_meta("studio-engine")
    assert_equal "lib/studio/version.rb", meta["version_file"]
    assert_equal "studio-engine.gemspec", meta["gemspec"]
    assert_equal "bin/release-check", meta["release_check"]
  end

  test "gem_meta is nil for a non-gem" do
    assert_nil Release::Repos.gem_meta("turf-monster")
    assert_nil Release::Repos.gem_meta("nope")
  end

  test "extract_version parses a VERSION constant assignment" do
    assert_equal "0.7.0", Release::Repos.extract_version(%(module Studio\n  VERSION = "0.7.0"\nend\n))
  end

  test "extract_version parses a gemspec version assignment" do
    assert_equal "0.4.7", Release::Repos.extract_version(%(  spec.version = "0.4.7"\n))
  end

  test "extract_version returns nil when no version is present" do
    assert_nil Release::Repos.extract_version("no version here")
    assert_nil Release::Repos.extract_version(nil)
  end

  test "gem_version is nil for a non-gem repo" do
    assert_nil Release::Repos.gem_version("turf-monster")
  end

  # --- apps as a hash: app_meta / prod_deploy / qa_app ---

  test "app_repos lists the registry's app hash keys" do
    assert_equal %w[mcritchie-studio turf-monster rolio tax-studio chain-ops].sort,
                 Release::Repos.app_repos.sort
  end

  test "app? matches the app hash keys" do
    assert Release::Repos.app?("mcritchie-studio")
    assert Release::Repos.app?("rolio")
    assert Release::Repos.app?("tax-studio")
    assert Release::Repos.app?("chain-ops")
    assert_not Release::Repos.app?("studio-engine") # a gem
    assert_not Release::Repos.app?("not-a-real-repo")
  end

  test "app_meta returns the app's registry metadata" do
    meta = Release::Repos.app_meta("turf-monster")
    assert_kind_of Hash, meta
    assert meta.key?("prod_deploy")
  end

  test "app_meta is nil for a non-app" do
    assert_nil Release::Repos.app_meta("studio-engine") # a gem
    assert_nil Release::Repos.app_meta("nope")
  end

  test "prod_deploy returns the git_push_heroku adapter for mcritchie-studio" do
    adapter = Release::Repos.prod_deploy("mcritchie-studio")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "heroku", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://mcritchie.studio", adapter["smoke_url"]
  end

  test "prod_deploy returns the repo_script adapter for turf-monster" do
    adapter = Release::Repos.prod_deploy("turf-monster")
    assert_equal "repo_script", adapter["strategy"]
    assert_equal "bin/deploy", adapter["command"]
    assert_equal ["--yes"], adapter["args"]
  end

  test "prod_deploy returns the Heroku URL adapter for Rolio" do
    adapter = Release::Repos.prod_deploy("rolio")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "https://git.heroku.com/rolio-prod.git", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://rolio-prod-82e96784b462.herokuapp.com", adapter["smoke_url"]
  end

  test "prod_deploy is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.prod_deploy("studio-engine")
    assert_nil Release::Repos.prod_deploy("not-a-real-repo")
  end

  test "qa_app defaults to the repo slug when no qa_deploy override is set" do
    assert_equal "rolio", Release::Repos.qa_app("rolio")
    assert_equal "turf-monster", Release::Repos.qa_app("turf-monster")
    assert_equal "mcritchie-studio", Release::Repos.qa_app("mcritchie-studio")
  end

  # --- test_cmd: the conductor's pre-prod gate ---

  test "test_cmd returns the hub's pre-prod gate command" do
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.test_cmd("mcritchie-studio")
  end

  test "test_cmd returns Rolio's pre-prod gate command" do
    assert_equal "bin/rails test", Release::Repos.test_cmd("rolio")
  end

  test "test_cmd is nil for a self-gating repo_script satellite" do
    # Satellites run their own suite in bin/deploy, so they leave test_cmd unset
    # (the conductor skips the gate) to avoid double-testing.
    assert_nil Release::Repos.test_cmd("turf-monster")
    assert_nil Release::Repos.test_cmd("tax-studio")
  end

  test "test_cmd is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.test_cmd("studio-engine")
    assert_nil Release::Repos.test_cmd("not-a-real-repo")
  end

  # --- qa_test_cmd: Steffon's pre-QA gate (G3 Candidate) ---

  test "qa_test_cmd registers the G3 tier per app: hub full suite, satellites integration subset" do
    # The prepare-owned tier. SATELLITES gate on the integration SUBSET (review
    # owns base; their ship test_cmd / own deploy owns the full run). The HUB
    # gates on its FULL suite — the G3 batch certification (90/10): ship's
    # test_gate then self-gates when the frozen SHA matches this certified run,
    # so the full suite still runs once per release batch.
    assert_equal "bin/rails db:test:prepare test test:system",
                 Release::Repos.qa_test_cmd("mcritchie-studio"),
                 "the hub certifies its full suite — base AND system tiers — at G3"
    %w[turf-monster rolio].each do |repo|
      assert_equal "bin/rails test test/integration", Release::Repos.qa_test_cmd(repo),
                   "#{repo} must gate QA on its integration tier"
    end
  end

  test "qa_test_cmd stays flag-style so the argv parse is unambiguous" do
    # Shellwords and String#split agree on these values (no quotes) — pins the
    # behavior-preserving half of the test_cmd_argv switch at the registry.
    %w[mcritchie-studio turf-monster rolio].each do |repo|
      cmd = Release::Repos.qa_test_cmd(repo)
      assert_equal cmd.split, Shellwords.split(cmd), "#{repo} qa_test_cmd must parse identically both ways"
    end
  end

  test "qa_test_cmd is nil for planned apps without a runnable integration tier" do
    # tax-studio has no sibling checkout yet; chain-ops' test/integration is
    # empty — both self-gate (the prepare gate skips) until they grow the tier.
    assert_nil Release::Repos.qa_test_cmd("tax-studio")
    assert_nil Release::Repos.qa_test_cmd("chain-ops")
  end

  test "qa_test_cmd is nil for a gem or an unknown repo" do
    assert_nil Release::Repos.qa_test_cmd("studio-engine")
    assert_nil Release::Repos.qa_test_cmd("not-a-real-repo")
  end

  # --- the hub's gate must cover what CI covers (the G3 system-test gap) ---

  test "the hub's G3 gate runs CI's test command verbatim" do
    # THE DRIFT GUARD, and the reason this file now parses ci.yml instead of
    # re-pinning a literal. `bin/rails test` SKIPS test/system — so while the gate
    # ran that and CI ran `db:test:prepare test test:system`, the gate's "full
    # suite" was NOT CI's full suite and a system-test regression rode the release
    # branch into QA ungated. A hard-coded string could drift out from under CI
    # again in silence; asserting against ci.yml itself means changing either side
    # alone fails HERE, at the seam, with the tiers named.
    assert_equal ci_test_command, Release::Repos.qa_test_cmd("mcritchie-studio"),
                 "the hub's G3 gate must run CI's full suite (base + system tiers), verbatim"
  end

  test "the hub's ship gate matches its pre-QA gate so G4 can self-gate" do
    # Release::ShipSequence.ship_gate_skip? compares the command STRINGS verbatim
    # against what G3 recorded. If test_cmd drifts from qa_test_cmd, G4 can never
    # credit G3's certified run and the full suite runs a second time every ship.
    assert_equal Release::Repos.qa_test_cmd("mcritchie-studio"),
                 Release::Repos.test_cmd("mcritchie-studio"),
                 "G4's test_cmd and G3's qa_test_cmd must be the same string"
  end

  test "the hub's gate keeps db:test:prepare FIRST so rake runs both tiers" do
    # SHAPE TRAP — do not "simplify" this command. `test` is a real rails COMMAND,
    # so `bin/rails test test:system` parses `test:system` as a PATH and dies with
    # `LoadError: cannot load such file -- <root>/test:system`. Both tiers run only
    # because a leading NON-command (db:test:prepare) routes the line through RAKE,
    # where `test` and `test:system` are two separate tasks.
    argv = Shellwords.split(Release::Repos.qa_test_cmd("mcritchie-studio"))
    assert_equal %w[bin/rails db:test:prepare test test:system], argv
    assert_equal "db:test:prepare", argv[1],
                 "a rails-COMMAND first arg would parse the later tiers as file paths"
  end

  private
    # The single command ci.yml's `test` job runs — the suite CI certifies on every
    # PR. Located by content (`bin/rails`), not by step name, so renaming the step
    # doesn't silently blind the drift guard above.
    def ci_test_command
      ci    = YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml"), aliases: true)
      steps = ci.dig("jobs", "test", "steps") || []
      run   = steps.filter_map { |s| s["run"] }.find { |c| c.include?("bin/rails") }
      assert run.present?, "ci.yml's `test` job no longer has a bin/rails step — the drift guard is blind"
      run.strip
    end
end
