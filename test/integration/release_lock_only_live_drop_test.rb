# frozen_string_literal: true

require "test_helper"
require_relative "../lib/release_cli_harness"

# [integration] Task lock-only-deploy-hardening, review note 2. A lock-only app whose
# production deploy PASSED and whose `main` push then failed is dropped, and the
# record must say production runs it. The loop runs for real with only the
# transport stood in: the real bin/release deploy_app and prune_lock_only! build
# the board write, it is evaluated here against this database, and the release's
# own readers (the notes lines and the rollback plan) read it back.
class ReleaseLockOnlyLiveDropTest < ActiveSupport::TestCase
  class Cli < ReleaseCliHarness; end

  # The deploy and its smoke pass; the `main` push is refused. Every board write
  # is printed, base64, for this test to run.
  SETUP = <<~'RUBY'
    def conductor(ruby, read_only: false)
      puts("SNIPPET=" + [ruby].pack("m0"))
      {}
    end
    def gate_sop(*) = nil
    def record_merged_main(*) = nil
    def record_deployed_apps(*) = nil
    def deploy_already_live?(*) = false
    def heroku_releases(*, **) = []
    def push_frozen_main(repo, _sha)
      abort!("push of #{repo} main was rejected") if repo == "rantly"
    end
    def sh(*cmd, **)
      return ["200", true] if cmd[0].to_s.end_with?("curl")

      [nil, true]
    end
    def run_test_scope(*, **) = yield
  RUBY

  def board_writes(slug)
    groups = %([{ "repo" => "mcritchie-studio", "kind" => "app" }, ) +
             %({ "repo" => "rantly", "kind" => "app", "lock_only" => true, "prod_deploy" => ) +
             %({ "strategy" => "git_push_heroku", "remote" => "https://git.heroku.com/mcr-rantly.git", ) +
             %("branch" => "main", "smoke_url" => "https://rantly.example" } }])
    call = %(app_groups = #{groups}; repos = app_groups.dup; ) +
           %(deploy_apps(app_groups, { "rantly" => "abc1234def0", "mcritchie-studio" => "f00f00f" }, #{slug.inspect}); ) +
           %(prune_lock_only!(#{slug.inspect}, app_groups, repos))
    out = Cli.new("lock_only_live_drop").run_cli([ "--yes" ], call: call, setup: SETUP)
    out.scan(/^\s*SNIPPET=(\S+)/).flatten.map { |b64| b64.unpack1("m0") }
  end

  test "[integration] a passed deploy whose main push failed is recorded as dropped AND live, and read back so" do
    Release.delete_all
    release = Release.open!
    release.update!(metadata: (release.metadata || {}).merge(Release::LockOnlyConsumers::LOCK_ONLY_KEY => [ "rantly" ]))

    writes = board_writes(release.slug).select { |ruby| ruby.include?("LockOnlyConsumers.drop") }
    assert_equal 1, writes.size, "one drop write expected: #{writes.inspect}"
    capture_io { eval(writes.first, TOPLEVEL_BINDING.dup, "bin/release drop write") } # rubocop:disable Security/Eval

    meta = release.reload.metadata
    assert_includes Release::LockOnlyConsumers.dropped(meta).fetch("rantly"), "production runs abc1234"
    assert_equal({ "rantly" => "abc1234def0" }, Release::LockOnlyConsumers.live_after_drop(meta))
    assert_empty Release::LockOnlyConsumers.recorded(meta), "a dropped app is not carried"
    assert_includes Release::LockOnlyConsumers.notes_lines(meta).last, "Dropped after its deploy (lock bumps only): rantly"

    plan = Release::RollbackPlan.build(
      target: { "slug" => release.slug, "state" => "shipped", "deployed_sha" => "f00f00f",
                "shipped_shas" => { "mcritchie-studio" => "f00f00f" },
                "lock_only_dropped" => Release::LockOnlyConsumers.dropped(meta),
                "lock_only_live" => Release::LockOnlyConsumers.live_after_drop(meta),
                "repos" => [] },
      history: []
    )
    assert(plan.lines.any? { |l| l.include?("rantly was dropped") && l.include?("AFTER its deploy: production runs abc1234d") },
           plan.lines.join("\n"))
  end
end
