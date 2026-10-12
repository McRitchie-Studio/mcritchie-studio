# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "digest"
require "tmpdir"
require "fileutils"

# [integration] deploy's config self-heal, driven through the REAL script.
#
# /tasks/rolio-qa-marker-missing: required_config was applied ONLY by provision,
# and the recurring release sweep calls deploy — so rolio-qa ran for weeks with
# its declared QA_ENV missing while the drift report re-announced it every run.
# run_deploy now heals the drifted DECLARED subset before pushing. These probes
# drive heal_registry_config in a bare subprocess (bin/qa-server defines the
# same top-level helpers as bin/release.rb; loading both into one test process
# is the constant-poisoning class fixed on /tasks/qa-apps-hardcode-production-
# bucket), with the two Heroku seams replaced by recorders — no network, no
# mutation, ever.
class QaServerHealWiringTest < ActionDispatch::IntegrationTest
  QA_SERVER = Rails.root.join("bin", "qa-server")

  BARE = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def bare_env = SessionEnv.neutralized(BARE)

  # heal(config:, live:, repo:, ref:) runs heal_registry_config against a scripted
  # live-vars answer (defined under private below). Returns
  # { "patched" => <vars given to the PATCH seam, or nil>, "out" => stdout }.

  test "a drifted declared var is PATCHed with the declared value before deploy" do
    result = heal(config: { "slug" => "probe", "required_config" => { "QA_ENV" => "true" } },
                  live: {})

    assert_equal({ "QA_ENV" => "true" }, result["patched"])
    assert_includes result["out"], "QA_ENV", "the heal must say WHICH keys it patched"
    refute_includes result["out"], "\"true\"", "and never print a value"
  end

  test "a clean app is not PATCHed at all" do
    result = heal(config: { "slug" => "probe", "required_config" => { "QA_ENV" => "true" } },
                  live: { "QA_ENV" => "true" })

    assert_nil result["patched"], "an in-sync app must see zero config writes on deploy"
  end

  # nil from the read seam means "could not read", and ignorance must not heal:
  # patching over vars we could not see is the confident-wrong direction.
  test "an unreadable live side skips healing with a say-so" do
    script_live_nil = heal_with_nil_live(config: { "slug" => "probe",
                                                   "required_config" => { "QA_ENV" => "true" } })

    assert_nil script_live_nil["patched"]
    assert_includes script_live_nil["out"], "could not read"
  end

  # derive_config_value ABORTS (SystemExit) on a missing derived source — a
  # deploy must still deploy when it cannot heal, never die at the heal step.
  test "an unreadable declared side skips healing instead of killing the deploy" do
    result = heal(config: { "slug" => "probe",
                            "required_config" => { "QA_ENV" => "true" },
                            "derived_config" => { "HASH" => "sha256:no/such/file" },
                            "repo" => "/nonexistent" },
                  live: {})

    assert_nil result["patched"]
    assert_includes result["out"], "config heal skipped"
  end

  # ── /tasks/qa-server-idl-pair-heal ───────────────────────────────────────────
  # The heal wrote `sha256:config/turf_vault.idl.json` (the v0.25 hash ALONE) over
  # turf-monster-qa's {v0.25,v0.26} pin while SOLANA_VAULT_GOVERNANCE=on, and the
  # boot raised IdlMismatchError. Driven through the real script against a real
  # git tree, read at the deployed ref.
  V025 = JSON.dump("instructions" => [{ "name" => "deposit" }])
  V026 = JSON.dump("instructions" => [{ "name" => "deposit" }, { "name" => "init_governance" }])
  TURF_QA = { "slug" => "turf-monster", "repo" => "turf-monster", "heroku_app" => "probe-app",
              "required_config" => { "SOLANA_NETWORK" => "devnet" },
              "derived_config" => { "EXPECTED_IDL_HASH" => "idl_pair:config/turf_vault" } }.freeze

  def h(bytes) = Digest::SHA256.hexdigest(bytes)

  test "governance on: a live v025,v026 pin is left alone — the incident's write never happens" do
    with_turf_tree do |repo, sha|
      live = { "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on", "QA_ENV" => "true",
               "EXPECTED_IDL_HASH" => "#{h(V025)},#{h(V026)}" }
      result = heal(config: TURF_QA, live: live, repo: repo, ref: sha)

      assert_nil result["patched"], "the pair already accepts both shapes; healing it is the outage"
    end
  end

  test "governance on: a lone v025 pin heals to include the v026 hash it boots against" do
    with_turf_tree do |repo, sha|
      live = { "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on", "QA_ENV" => "true",
               "EXPECTED_IDL_HASH" => h(V025) }
      result = heal(config: TURF_QA, live: live, repo: repo, ref: sha)

      assert_equal({ "EXPECTED_IDL_HASH" => "#{h(V025)},#{h(V026)}" }, result["patched"])
      refute_includes result["out"], h(V026), "the heal names keys, never values"
    end
  end

  test "governance off with no v026 file shipped: heals to the one v025 hash" do
    with_turf_tree(files: { "config/turf_vault.idl.json" => V025 }) do |repo, sha|
      live = { "SOLANA_NETWORK" => "devnet", "QA_ENV" => "true" }
      result = heal(config: TURF_QA, live: live, repo: repo, ref: sha)

      assert_equal({ "EXPECTED_IDL_HASH" => h(V025) }, result["patched"])
    end
  end

  # The deploy's tree, not the checkout's: the primary's working tree can sit on
  # any branch, so the IDL is read at the ref being pushed.
  test "the IDL is read at the deployed ref, not the working tree" do
    with_turf_tree do |repo, sha|
      File.write(File.join(repo, "config/turf_vault.v026.idl.json"), V025) # dirty, wrong shape
      live = { "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on", "QA_ENV" => "true" }
      result = heal(config: TURF_QA, live: live, repo: repo, ref: sha)

      assert_equal "#{h(V026)},#{h(V025)}", result["patched"]["EXPECTED_IDL_HASH"]
    end
  end

  # An empty switch refuses in turf's rule; here that means the heal SKIPS
  # rather than writing a guessed pin.
  test "an empty governance switch skips the heal instead of guessing" do
    with_turf_tree do |repo, sha|
      live = { "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "", "QA_ENV" => "true" }
      result = heal(config: TURF_QA, live: live, repo: repo, ref: sha)

      assert_nil result["patched"]
      assert_includes result["out"], "config heal skipped"
    end
  end

  # ── deploy must not report green over a failed release phase ────────────────
  # Heroku v281-v283 failed while the old slug kept /up 200 and the sweep said
  # green. run_deploy is driven for real with every Heroku/git-push seam stubbed.
  test "a failed release phase makes qa-server deploy exit non-zero" do
    result = deploy(releases_after_push: [{ "version" => 281, "status" => "failed", "description" => "Deploy abc" },
                                          { "version" => 280, "status" => "succeeded", "description" => "x" }])

    refute result[:status].success?, "deploy exited 0 over a failed release:\n#{result[:out]}"
    assert_includes result[:out], "release phase"
    refute_includes result[:out], "NOTIFIED", "a failed deploy must not announce itself to Discord"
  end

  test "a succeeded release phase lets the deploy finish" do
    result = deploy(releases_after_push: [{ "version" => 281, "status" => "succeeded", "description" => "Deploy abc" },
                                          { "version" => 280, "status" => "succeeded", "description" => "x" }])

    assert result[:status].success?, result[:out]
    assert_includes result[:out], "NOTIFIED"
  end

  test "a release that never settles is not green" do
    result = deploy(releases_after_push: [{ "version" => 281, "status" => "pending", "description" => "Deploy abc" }])

    refute result[:status].success?
    assert_includes result[:out], "NOT CONFIRMED"
  end

  private

  def with_turf_tree(files: { "config/turf_vault.idl.json" => V025, "config/turf_vault.v026.idl.json" => V026 })
    Dir.mktmpdir("qa-idl-pair") do |repo|
      files.each do |path, bytes|
        FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
        File.write(File.join(repo, path), bytes)
      end
      git = ->(*args) { system("git", "-C", repo, *args, out: File::NULL, err: File::NULL) || raise("git #{args.first}") }
      git.call("init", "-q")
      git.call("add", "-A")
      git.call("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "idl")
      sha = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).strip
      yield repo, sha
    end
  end

  def heal(config:, live:, repo: nil, ref: nil)
    script = <<~RUBY
      require "json"
      require "stringio"
      load #{QA_SERVER.to_s.inspect}

      LIVE = JSON.parse(#{JSON.dump(JSON.dump(live))})
      RECORDED = { "patched" => nil }
      def heroku_get_config_vars(_app) = LIVE
      def heroku_patch_config_vars(_app, vars) = RECORDED["patched"] = vars
      #{"def repo_path(_config) = #{repo.inspect}" if repo}

      out = StringIO.new
      $stdout = out
      begin
        heal_registry_config("probe-app", JSON.parse(#{JSON.dump(JSON.dump(config))}), ref: #{ref.inspect})
      ensure
        $stdout = STDOUT
      end
      puts JSON.dump(RECORDED.merge("out" => out.string))
    RUBY

    out, status = Open3.capture2(bare_env, RbConfig.ruby, "-e", script, err: File::NULL)
    assert status.success?, "the heal probe itself failed:\n#{out}"
    JSON.parse(out.lines.last)
  end

  # run_deploy with its seams replaced: the release list answers 280 before the
  # push and `releases_after_push` after it; nothing reaches Heroku or a remote.
  def deploy(releases_after_push:)
    with_turf_tree do |repo, sha|
      script = <<~RUBY
        require "json"
        load #{QA_SERVER.to_s.inspect}

        AFTER = JSON.parse(#{JSON.dump(JSON.dump(releases_after_push))})
        PUSHED = [false]
        def qa_for(_name) = { "slug" => "probe", "heroku_app" => "probe-app", "repo" => "probe",
                              "qa_url" => "https://qa.example.test", "required_config" => { "QA_ENV" => "true" } }
        def repo_path(_config) = #{repo.inspect}
        def heroku_app_exists?(_app) = true
        def heroku_get_config_vars(_app) = { "QA_ENV" => "true" }
        def heroku_patch_config_vars(_app, _vars) = raise("no PATCH expected")
        def heroku_releases(_app) = PUSHED[0] ? AFTER : [{ "version" => 280, "status" => "succeeded" }]
        def sh(*cmd, chdir: nil)
          raise "unexpected command: \#{cmd.first}" unless cmd.first == "git" && cmd[1] == "push"
          PUSHED[0] = true
        end
        def heroku_web_url(_config) = "https://probe.example.test"
        def health_code(_url) = "200"
        def notify_discord_deploy(*) = puts("NOTIFIED")
        def sleep(_s) = nil

        run_deploy("probe", #{sha.inspect}, assume_yes: true)
      RUBY

      out, status = Open3.capture2e(bare_env.merge("QA_SERVER_RELEASE_POLLS" => "3"), RbConfig.ruby, "-e", script)
      return { out: out, status: status }
    end
  end

  def heal_with_nil_live(config:)
    script = <<~RUBY
      require "json"
      require "stringio"
      load #{QA_SERVER.to_s.inspect}

      RECORDED = { "patched" => nil }
      def heroku_get_config_vars(_app) = nil
      def heroku_patch_config_vars(_app, vars) = RECORDED["patched"] = vars

      out = StringIO.new
      $stdout = out
      begin
        heal_registry_config("probe-app", JSON.parse(#{JSON.dump(JSON.dump(config))}))
      ensure
        $stdout = STDOUT
      end
      puts JSON.dump(RECORDED.merge("out" => out.string))
    RUBY

    out, status = Open3.capture2(bare_env, RbConfig.ruby, "-e", script)
    assert status.success?, "the nil-live probe itself failed:\n#{out}"
    JSON.parse(out.lines.last)
  end
end
