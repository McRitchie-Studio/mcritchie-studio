require "test_helper"
require "shellwords"
require "open3"

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

  test "self_gated_gem? is true only for a gem carrying a non-empty release_check" do
    # studio-engine declares release_check: bin/release-check → self-gated.
    assert Release::Repos.self_gated_gem?("studio-engine")
    # solana-studio has no release_check → not self-gated (still needs a consumer).
    assert_not Release::Repos.self_gated_gem?("solana-studio")
    # apps and unknowns are never self-gated gems.
    assert_not Release::Repos.self_gated_gem?("mcritchie-studio")
    assert_not Release::Repos.self_gated_gem?("turf-monster")
    assert_not Release::Repos.self_gated_gem?("not-a-real-repo")
    assert_not Release::Repos.self_gated_gem?(nil)
    assert_not Release::Repos.self_gated_gem?("")
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
    assert_equal %w[mcritchie-studio turf-monster mcritchie-industries rolio tax-studio chain-ops].sort,
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

  test "prod_deploy returns the github_actions adapter for mcritchie-studio" do
    # DevOps v2 Phase 2: the hub deploys through GitHub Actions (prod-deploy.yml),
    # not a local git push. smoke_url stays for the board/deploy record even though
    # the workflow (not the conductor) runs the smoke.
    adapter = Release::Repos.prod_deploy("mcritchie-studio")
    assert_equal "github_actions", adapter["strategy"]
    assert_equal "prod-deploy.yml", adapter["workflow"]
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
    # CI's full suite, verbatim — base AND system tiers. Rolio deploys via
    # git_push_heroku (no test step), so this command IS the last gate before
    # rolio production; `bin/rails test` (what it used to be) SKIPS test/system,
    # which left rolio's system tier able to regress straight into prod ungated.
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.test_cmd("rolio")
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

  test "qa_test_cmd registers the G3 tier per app: full CI suite unless the repo's own deploy tests" do
    # The prepare-owned tier. The split is NOT "hub vs satellite" — it is "does
    # this repo's DEPLOY run the suite?":
    #   * turf-monster's bin/deploy runs the full suite pre-prod, so G3 gates on
    #     the integration SUBSET (review owns base) and ship doesn't double-test.
    #   * the HUB and ROLIO both deploy via git_push_heroku, which has NO test
    #     step — so their registered command is the LAST gate before prod and must
    #     be CI's FULL suite (base AND system tiers). It is also the G3 batch
    #     certification (90/10): ship's test_gate self-gates when the frozen SHA
    #     matches this certified run, so the suite runs once per release batch.
    assert_equal "bin/rails db:test:prepare test test:system",
                 Release::Repos.qa_test_cmd("mcritchie-studio"),
                 "the hub certifies its full suite — base AND system tiers — at G3"
    assert_equal "bin/rails db:test:prepare test test:system", Release::Repos.qa_test_cmd("rolio"),
                 "rolio is git_push_heroku — its gate must certify CI's full suite, base AND system tiers"
    assert_equal "bin/rails test test/integration", Release::Repos.qa_test_cmd("turf-monster"),
                 "turf-monster self-gates the full suite in bin/deploy, so G3 gates on its integration tier"
  end

  # --- rolio's gate must cover what rolio's CI covers (the system-test gap) ---

  test "rolio's gate carries the SYSTEM tier" do
    # THE BUG THIS CLOSES. rolio HAS system tests (test/system/) and its ci.yml
    # runs them, but both registered commands were `bin/rails test` (G4) and
    # `bin/rails test test/integration` (G3) — BOTH of which SKIP test/system. With
    # git_push_heroku carrying no test step, a system-test regression could reach
    # rolio production completely ungated.
    %w[qa_test_cmd test_cmd].each do |field|
      cmd = Release::Repos.public_send(field, "rolio")
      assert_includes cmd, "test:system",
                      "rolio's #{field} must run the system tier — its deploy has no test step, so this " \
                      "command is the last gate before prod"
    end
  end

  test "rolio's ship gate matches its pre-QA gate so G4 can self-gate" do
    # Release::ShipSequence.ship_gate_skip? compares the command STRINGS verbatim
    # against what G3 recorded. If test_cmd drifts from qa_test_cmd, G4 can never
    # credit G3's certified run and the full suite runs a second time every ship.
    assert_equal Release::Repos.qa_test_cmd("rolio"), Release::Repos.test_cmd("rolio"),
                 "rolio's G4 test_cmd and G3 qa_test_cmd must be the same string"
  end

  test "rolio's gate keeps db:test:prepare FIRST so rake runs both tiers" do
    # SHAPE TRAP — do not "simplify" this command. `test` is a real rails COMMAND,
    # so `bin/rails test test:system` parses `test:system` as a PATH and dies with
    # `LoadError: cannot load such file -- <root>/test:system`. Both tiers run only
    # because a leading NON-command (db:test:prepare) routes the line through RAKE,
    # where `test` and `test:system` are two separate tasks.
    argv = Shellwords.split(Release::Repos.qa_test_cmd("rolio"))
    assert_equal %w[bin/rails db:test:prepare test test:system], argv
    assert_equal "db:test:prepare", argv[1],
                 "a rails-COMMAND first arg would parse the later tiers as file paths"
  end

  test "rolio's gate runs rolio's CI test command verbatim" do
    # THE DRIFT GUARD. Asserting against rolio's OWN ci.yml (not a literal) means
    # changing either side alone fails HERE, at the seam. rolio's ci.yml lives in
    # the SIBLING checkout, so this binds locally and in the gate workspace (where
    # G3/G4 actually run) and skips on the hub's GitHub runner, which checks out
    # only this repo. The shape assertions above bind everywhere.
    ci = sibling_ci_test_command("rolio")
    skip "rolio checkout not present (hub CI runner) — shape guards above still bind" if ci.nil?

    assert_equal ci, Release::Repos.qa_test_cmd("rolio"),
                 "rolio's G3 gate must run rolio CI's full suite (base + system tiers), verbatim"
  end

  # --- mcritchie-industries: git_push_heroku, so it gates like rolio ---

  test "mcritchie-industries' prod_deploy is git_push_heroku onto the canonical host" do
    adapter = Release::Repos.prod_deploy("mcritchie-industries")
    assert_equal "git_push_heroku", adapter["strategy"]
    assert_equal "https://git.heroku.com/mcritchie-industries.git", adapter["remote"]
    assert_equal "main", adapter["branch"]
    assert_equal "https://www.mcritchie.industries", adapter["smoke_url"]
  end

  test "mcritchie-industries registers CI's full suite at BOTH gates" do
    # git_push_heroku has NO test step, so the registered command is the last
    # gate before production and must be CI's full suite verbatim. This repo has
    # NO system tier yet (test/system holds only a .keep; its own
    # ci_workflow_test.rb pins the plain-`test` shape) — so, deliberately, no
    # `test:system` here. Same string at both gates so G4 can self-gate on G3.
    %w[test_cmd qa_test_cmd].each do |field|
      assert_equal "bin/rails db:test:prepare test",
                   Release::Repos.public_send(field, "mcritchie-industries"),
                   "#{field} must be mcritchie-industries CI's full suite, verbatim"
    end
  end

  test "mcritchie-industries' gate runs its CI test command verbatim" do
    # THE DRIFT GUARD, rolio-style: asserted against the repo's OWN ci.yml at
    # origin/release, so when its first system test lands and ci.yml grows
    # `test:system`, this fails at the seam until the registry grows it too.
    # Anchored on the suite step (db:test:prepare) because this repo's test job
    # runs `bin/rails tailwindcss:build` BEFORE the suite — the bin/rails
    # anchor would find the asset build, not the gate command.
    ci = sibling_ci_test_command("mcritchie-industries", anchor: "db:test:prepare")
    skip "mcritchie-industries checkout not present (hub CI runner) — shape guards above still bind" if ci.nil?

    assert_equal ci, Release::Repos.qa_test_cmd("mcritchie-industries"),
                 "mcritchie-industries' G3 gate must run its CI suite, verbatim"
  end

  test "turf-monster has no system tests, so its integration subset is the right gate" do
    # Verified, not assumed: turf-monster's test/system holds only a .keep, so
    # there is no system tier to cover and bin/deploy's full suite is sufficient.
    root = projects_root
    skip "turf-monster checkout not present (hub CI runner)" if root.nil?

    system_tests = Dir[root.join("turf-monster", "test", "system", "**", "*_test.rb")]
    assert_empty system_tests,
                 "turf-monster grew system tests — its gate (bin/deploy's suite) must now cover them, the " \
                 "same gap this file closes for rolio"
  end

  private
    # The projects root holding the sibling checkouts. Resolved by ASCENDING from
    # Rails.root until a directory containing the sibling repos appears, so it works
    # from a primary checkout, an agent worktree, AND the gate workspace
    # (.worktrees/_gate), which sit at different depths. nil when absent (hub CI).
    def projects_root
      Rails.root.ascend.find { |dir| dir.join("rolio", ".git").exist? }
    end

    # The single command a sibling repo's ci.yml `test` job runs. Located by content
    # (`bin/rails` by default; pass anchor: for a repo whose test job runs OTHER
    # bin/rails steps before the suite), not by step name, so renaming the step
    # cannot silently blind the drift guard. nil when the sibling isn't checked out.
    #
    # Read from `origin/release`, NOT the sibling's WORKING TREE. The working tree is
    # whatever branch that checkout happens to sit on — so an agent editing rolio's
    # ci.yml on a feature branch would turn THE HUB's gate red for a change that is
    # nowhere near the release. The registry gates the code that SHIPS, so it is held
    # against the branch that ships.
    def sibling_ci_test_command(repo, anchor: "bin/rails")
      root = projects_root
      return nil if root.nil?

      path = root.join(repo)
      raw, ok = Open3.capture2("git", "-C", path.to_s, "show", "origin/release:.github/workflows/ci.yml")
      return nil unless ok.success?

      ci    = YAML.safe_load(raw, aliases: true)
      steps = ci.dig("jobs", "test", "steps") || []
      run   = steps.filter_map { |s| s["run"] }.find { |c| c.include?(anchor) }
      assert run.present?, "#{repo}'s ci.yml `test` job no longer has a #{anchor} step — the guard is blind"
      run.strip
    end

  test "qa_test_cmd stays flag-style so the argv parse is unambiguous" do
    # Shellwords and String#split agree on these values (no quotes) — pins the
    # behavior-preserving half of the test_cmd_argv switch at the registry.
    %w[mcritchie-studio turf-monster mcritchie-industries rolio].each do |repo|
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
