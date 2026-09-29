# frozen_string_literal: true

# [unit] AppProfile and AppContract — the deploy-profile expansion bin/register-app
# writes, and the contract checks it runs first. The contract tests drive fake
# probes; the one subprocess test (bin/register-app from a tree without
# app/helpers) runs the real CLI, which calls git and heroku for real.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "../../bin/lib/app_profile"
require_relative "../../bin/lib/app_contract"

class AppProfileTest < Minitest::Test
  PARAMS = { heroku_app: "mcr-demo", smoke_url: "https://demo.mcritchie.studio", test_cmd: "bin/rails test" }.freeze

  def test_expand_fills_the_standalone_profile
    entry = AppProfile.expand("standalone-heroku", PARAMS)

    assert_equal "standalone-heroku", entry["profile"]
    assert_equal "three-rung", entry["ladder"]
    assert_equal({ "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/mcr-demo.git",
                   "branch" => "main", "smoke_url" => "https://demo.mcritchie.studio" }, entry["prod_deploy"])
    assert_equal "bin/rails test", entry["test_cmd"]
    assert_equal "exempt", entry["qa_evidence"]
  end

  def test_expand_refuses_a_blank_or_multiline_param
    assert_raises(AppProfile::Error) { AppProfile.expand("standalone-heroku", PARAMS.merge(test_cmd: "")) }
    assert_raises(AppProfile::Error) { AppProfile.expand("standalone-heroku", PARAMS.merge(heroku_app: "a\nb: c")) }
  end

  def test_unknown_profile_names_the_known_ones
    error = assert_raises(AppProfile::Error) { AppProfile.expand("nope", PARAMS) }
    assert_match(/standalone-heroku/, error.message)
  end

  def test_an_expanded_entry_has_no_drift_and_a_hand_edit_does
    entry = AppProfile.expand("standalone-heroku", PARAMS)
    assert_empty AppProfile.drift(entry)

    edited = Marshal.load(Marshal.dump(entry))
    edited["prod_deploy"]["branch"] = "master"
    edited["qa_test_cmd"] = "bin/rails test"
    drift = AppProfile.drift(edited)
    assert_includes drift, 'prod_deploy.branch: expected "main", found "master"'
    assert(drift.any? { |line| line.start_with?("qa_test_cmd:") }, "an extra key is drift too")
  end

  def test_render_round_trips_through_yaml_under_apps
    entry = AppProfile.expand("standalone-heroku", PARAMS)
    text = "apps:\n#{AppProfile.render('demo', entry, notes: ['a note'])}"

    parsed = YAML.safe_load(text).dig("apps", "demo")
    assert_equal entry, parsed
    assert_includes text, "# a note"
  end

  # --- AppContract ------------------------------------------------------------

  class FakeProbe
    def initialize(files: {}, runs: {}, http: {}) = (@files, @runs, @http = files, runs, http)
    attr_reader :refs_read

    def read(path) = @files[File.basename(path) == "ci.yml" ? "ci.yml" : File.basename(path)]

    def read_at(_root, ref, relpath)
      (@refs_read ||= []) << ref
      read(relpath)
    end
    def http_status(url) = @http[url]

    def run(*argv)
      key = if argv.include?("get-url") then :origin
            elsif argv.include?("ls-remote") then :heads
            elsif argv.include?("fetch") then :fetch
            else argv.first.to_sym
            end
      @runs.fetch(key, ["", false])
    end
  end

  CI = { "on" => { "pull_request" => nil, "push" => { "branches" => %w[main release accepted] } },
         "jobs" => { "test" => { "steps" => [{ "uses" => "actions/checkout@v4" },
                                             { "run" => "bin/rails db:test:prepare test" }] } } }.to_yaml

  def healthy_probe(**over)
    FakeProbe.new(
      files: { "ci.yml" => CI, ".gitignore" => "/log\n.worktrees/\n", "Gemfile" => "gem \"pg\"\n",
               "Procfile" => "web: puma\nrelease: bin/rails db:migrate\n" }.merge(over.fetch(:files, {})),
      runs: { origin: ["https://github.com/McRitchie-Studio/demo.git\n", true],
              heads: ["a\trefs/heads/main\nb\trefs/heads/accepted\nc\trefs/heads/release\n", true],
              fetch: ["", true], heroku: ["=== demo", true] }.merge(over.fetch(:runs, {})),
      http: { "https://demo.example.com/up" => 200 }.merge(over.fetch(:http, {}))
    )
  end

  def contract(probe) = AppContract.run(slug: "demo", heroku_app: "demo", smoke_url: "https://demo.example.com/", root: "/x/demo", probe: probe)

  def test_a_healthy_app_passes_every_check_and_yields_its_ci_test_command
    checks, test_cmd = contract(healthy_probe)

    assert(checks.all?(&:ok), checks.reject(&:ok).map(&:name).inspect)
    assert_equal "bin/rails db:test:prepare test", test_cmd
    assert_includes checks.map(&:name), "migrations", "a pg app is checked for its release-phase migrate"
  end

  def test_each_gap_fails_its_own_check_with_a_remedy
    probe = healthy_probe(files: { ".gitignore" => "/log\n", "Procfile" => "web: puma\n" },
                          runs: { heads: ["a\trefs/heads/main\n", true], heroku: ["", false] },
                          http: { "https://demo.example.com/up" => 503 })
    failed = contract(probe).first.reject(&:ok)

    assert_equal ["branches", ".worktrees ignored", "heroku app", "smoke /up", "migrations"], failed.map(&:name)
    assert(failed.all? { |c| !c.remedy.to_s.empty? }, "every failure says how to fix it")
    assert_match(/missing accepted, release/, failed.first.detail)
  end

  def test_every_file_check_reads_the_branch_a_release_ships
    probe = healthy_probe
    contract(probe)
    assert_equal ["origin/accepted"], probe.refs_read.uniq,
                 "the contract judges accepted, not the primary checkout's working tree"
  end

  def test_ci_that_skips_the_release_rungs_fails_the_contract
    main_only = { "on" => { "push" => { "branches" => ["main"] } },
                  "jobs" => { "test" => { "steps" => [{ "run" => "bin/rails test" }] } } }.to_yaml
    failed = contract(healthy_probe(files: { "ci.yml" => main_only })).first.reject(&:ok)
    assert_equal ["ci on release rungs"], failed.map(&:name)
    assert_match(/push skips accepted, release/, failed.first.detail)
  end

  def test_ci_push_branches_reads_every_spelling
    assert_equal %w[main release accepted], AppContract.ci_push_branches("on:\n  push:\n    branches: [ main, release, accepted ]\n")
    assert_equal :all, AppContract.ci_push_branches("on:\n  push:\n  pull_request:\n")
    assert_equal :all, AppContract.ci_push_branches("on: [push, pull_request]\n")
    assert_equal [], AppContract.ci_push_branches("on:\n  pull_request:\n")
    assert_equal [], AppContract.ci_push_branches(nil)
  end

  def test_a_failed_fetch_fails_the_contract
    failed = contract(healthy_probe(runs: { fetch: ["fatal: could not read Username", false] })).first.reject(&:ok)
    assert_equal ["fetch"], failed.map(&:name), "a stale origin/accepted must not pass silently"
  end

  HELPER = <<~RUBY
    module ApplicationHelper
      OTHER = {
        "demo" => "not a glyph"
      }.freeze

      APP_EMOJIS = {
        "rantly" => "📣",
        "moms-app" => "📚"
      }.freeze
    end
  RUBY

  def test_glyph_check_reads_only_the_app_emojis_hash
    assert AppContract.glyph_check(HELPER, "moms-app").ok
    refute AppContract.glyph_check(HELPER, "demo").ok, "a match in another hash must not pass"
    refute AppContract.glyph_check("module X; end", "moms-app").ok
  end

  def test_register_app_from_a_tree_without_app_helpers_fails_the_glyph_check_instead_of_crashing
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.expand_path("../../bin", __dir__), dir)
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.cp(File.expand_path("../../config/app_profiles.yml", __dir__), File.join(dir, "config"))
      File.write(File.join(dir, "config", "release_repos.yml"), "apps: {}\n")
      out, status = Open3.capture2e({ "PROJECTS_DIR" => dir }, "ruby", File.join(dir, "bin", "register-app"),
                                    "nope-app", "--heroku-app", "nope-app", "--smoke-url", "https://127.0.0.1:9")
      refute_match(/Errno::ENOENT/, out)
      assert_match(/FAIL  hub badge glyph\s+no app\/helpers here/, out)
      assert_equal 1, status.exitstatus
    end
  end

  def test_a_non_pg_app_is_not_asked_for_migrations
    checks, = contract(healthy_probe(files: { "Gemfile" => "gem \"rails\"\n" }))
    refute_includes checks.map(&:name), "migrations"
  end

  def test_ci_test_cmd_needs_exactly_one_rails_step_in_the_test_job
    two = { "jobs" => { "test" => { "steps" => [{ "run" => "bin/rails test" }, { "run" => "bin/rails test:system" }] } } }.to_yaml
    assert_nil AppContract.ci_test_cmd(two), "two suite steps cannot be named as one test_cmd"
    assert_nil AppContract.ci_test_cmd(nil)
    assert_equal "bin/rails test", AppContract.ci_test_cmd({ "jobs" => { "test" => { "steps" => [{ "run" => "bin/rails test" }] } } }.to_yaml)
  end

  def test_engine_version_reads_the_lock
    assert_equal "0.32.1", AppContract.engine_version("GEM\n  specs:\n    studio-engine (0.32.1)\n      rails\n")
    assert_nil AppContract.engine_version("GEM\n  specs:\n    rails (8.1.0)\n")
  end

  # --- the CLI's refusals ----------------------------------------------------------

  CLI = File.expand_path("../../bin/register-app", __dir__)

  def test_help_answers_and_an_unknown_flag_refuses
    out, status = Open3.capture2e("ruby", CLI, "--help")
    assert status.success?
    assert_match(/usage: bin\/register-app/, out)

    out, status = Open3.capture2e("ruby", CLI, "demo", "--heroku-app", "x", "--smoke-url", "https://x", "--bogus")
    assert_equal 2, status.exitstatus
    assert_match(/NOTHING was checked or written/, out)
  end

  def test_write_refuses_outside_a_git_checkout
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(%w[bin config].map { |d| File.expand_path("../../#{d}", __dir__) }, dir)
      out, status = Open3.capture2e("ruby", File.join(dir, "bin/register-app"), "demo", "--heroku-app", "x", "--smoke-url", "https://x", "--write")
      assert_equal 1, status.exitstatus
      assert_match(/not a git checkout.*NOTHING was written/, out)
    end
  end

  def test_missing_required_flags_prints_usage
    out, status = Open3.capture2e("ruby", CLI, "demo")
    assert_equal 2, status.exitstatus
    assert_match(/--heroku-app/, out)
  end
end
