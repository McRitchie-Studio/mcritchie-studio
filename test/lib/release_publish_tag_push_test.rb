# frozen_string_literal: true

# [integration] publish_gem's TAG PUSH, when it fails (/tasks/untagged-gem-publish-strands-work).
#
# publish_gem pushes the gem, then tags and pushes the tag. The gem is live by then,
# so a failed tag push stays NON-FATAL: aborting would strand the sweep's consumer
# lock bumps and QA for a publish that succeeded. What changed is that it is no
# longer quiet. The old line, "push it manually if needed", read as optional
# housekeeping while every later sweep from a clone without the tag skipped the gem
# for good. Allocation now refuses that state; this pins the moment it is created.
#
# Drives the REAL publish_gem in a subprocess that has `load`ed bin/release.rb (its
# dispatch is guarded on __FILE__ == $PROGRAM_NAME). `sh` is stubbed because gem
# build/push and the tag push are network; the stub fails ONLY the tag push.
#
#   ruby -Itest test/lib/release_publish_tag_push_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../support/session_env"

class ReleasePublishTagPushTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  BUNDLER_ENV_KEYS = %w[RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP].freeze

  def publish(tag_push_ok:)
    Dir.mktmpdir("publish-tag") do |root|
      script = <<~SCRIPT
        load #{BIN.inspect}
        def repo_path(_repo) = #{root.inspect}
        def sh(*a, **_k)
          if a[0] == "git" && a.include?("push") && a.last.to_s.match?(/\\Av\\d/)
            $stdout.puts("TAG-PUSH #{tag_push_ok ? 'ok' : 'refused'}")
            return ["! [remote rejected] (tag pushes refused)", #{tag_push_ok}]
          end
          $stdout.puts("SH " + a.first(2).join(" "))
          ["", true]
        end
        publish_gem("studio-engine", "1.0.0")
        puts "RETURNED"
      SCRIPT
      env = SessionEnv.neutralized(BUNDLER_ENV_KEYS.to_h { |key| [key, nil] }.merge("PROJECTS_DIR" => root))
      out, status = Open3.capture2e(env, RbConfig.ruby, "-W0", "-e", script)
      [out, status.success?]
    end
  end

  def test_a_failed_tag_push_is_loud_names_the_push_and_does_not_abort
    out, ok = publish(tag_push_ok: false)

    assert ok, "the gem is already live, so the failed tag push must not abort:\n#{out}"
    assert_includes out, "TAG-PUSH refused", "the harness must really fail the tag push"
    assert_includes out, "⚠ tag v1.0.0 did NOT reach origin — push it now"
    assert_includes out, "push origin v1.0.0", "it names the exact push"
    assert_includes out, "REFUSES studio-engine", "and what happens if nobody does"
    refute_includes out, "push it manually if needed"
    assert_includes out, "RETURNED"
  end

  def test_a_tag_push_that_lands_says_so_quietly
    out, ok = publish(tag_push_ok: true)

    assert ok, out
    assert_includes out, "(tag v1.0.0 push ok)"
    refute_includes out, "did NOT reach origin"
  end
end
