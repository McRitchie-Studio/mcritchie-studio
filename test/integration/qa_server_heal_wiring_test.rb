# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"

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

  # Run heal_registry_config against a scripted live-vars answer. Returns
  # { "patched" => <vars given to the PATCH seam, or nil>, "out" => stdout }.
  def heal(config:, live:)
    script = <<~RUBY
      require "json"
      require "stringio"
      load #{QA_SERVER.to_s.inspect}

      LIVE = JSON.parse(#{JSON.dump(JSON.dump(live))})
      RECORDED = { "patched" => nil }
      def heroku_get_config_vars(_app) = LIVE
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
    assert status.success?, "the heal probe itself failed:\n#{out}"
    JSON.parse(out.lines.last)
  end

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

  private

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
