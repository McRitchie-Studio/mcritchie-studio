# frozen_string_literal: true

# [unit] bin/release finalize's live-on-prod guard and the reads under it, with the
# board, Heroku, GitHub and production stubbed in the child.
#
# THE INCIDENT — rel-20261029-00560a. The ship deployed every app, then a dry
# `bin/release finalize` refused all of them: alex-build, voicebox and turf-monster
# because the guard demanded the CURRENT Heroku release be the Deploy (turf's
# bin/deploy sets EXPECTED_IDL_HASH after its push, and a dry run read no releases
# at all), and the hub because an unreadable `gh run list` read as "no successful
# run at the frozen SHA". The guard now asks the same through-config question as
# `bin/release cycle`'s prod verify, reads live under --dry-run, and retries the run
# list once on a credential refusal.
#
#   ruby -Itest test/lib/release_cli_finalize_guard_test.rb
require_relative "release_cli_harness"

class ReleaseCliFinalizeGuardTest < ReleaseCliHarness
  FROZEN = "0988886c1f2e3d4c5b6a798877665544332211aa"

  TURF = { "repo" => "turf-monster", "kind" => "app", "members" => [],
           "prod_deploy" => { "strategy" => "repo_script", "heroku_app" => "turf-monster-mainnet",
                              "smoke_url" => "https://turf.example" } }.freeze

  CONFIG_ON_TOP = [
    { "version" => 286, "description" => "Set EXPECTED_IDL_HASH config vars", "status" => "succeeded", "current" => true },
    { "version" => 285, "description" => "Deploy 0988886c", "status" => "succeeded", "current" => false }
  ].freeze

  OTHER_DEPLOY_LIVE = [
    { "version" => 287, "description" => "Deploy deadbeef", "status" => "succeeded", "current" => true },
    { "version" => 286, "description" => "Set EXPECTED_IDL_HASH config vars", "status" => "succeeded", "current" => false },
    { "version" => 285, "description" => "Deploy 0988886c", "status" => "succeeded", "current" => false }
  ].freeze

  # A dry finalize of one release whose only app is turf-monster at FROZEN, with
  # `releases` as its Heroku history. The claim and board reads are stubbed; the
  # guard's own deploy_live_verdict and heroku_releases run for real, over a stubbed
  # `heroku` subprocess.
  def finalize_with(releases)
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        return { "slug" => "rel-x" } if ruby.include?("puts({slug: r.slug}")
        { "slug" => "rel-x", "state" => "assembled", "sealed" => true, "notes_completed" => true,
          "members_all_shipped" => false, "repos" => [#{TURF.inspect}], "qa_shas" => { "turf-monster" => #{FROZEN.inspect} } }
      end
      def conductor_claim(*a) = ReleaseClaimCli::OK
      def bounded_capture3(*argv, **_opts)
        $stdout.puts("HEROKU " + argv.join(" ")) if argv.first == "heroku"
        [#{JSON.generate(releases).inspect}, "", Struct.new(:ok) { def success? = ok }.new(true)]
      end
      def prod_up_ok?(_url) = true
      def origin_main_sha(_repo) = #{FROZEN.inspect}
    RUBY
    run_cli(["--dry-run", "--yes"], setup: setup,
                                    call: "begin; finalize('rel-x'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")
  end

  def test_finalize_passes_its_guard_with_a_config_release_on_top_of_the_deploy
    out = finalize_with(CONFIG_ON_TOP)

    assert_includes out, "HEROKU heroku releases --app turf-monster-mainnet",
                    "a dry finalize reads Heroku live; a read mutates nothing"
    assert_includes out, "1 app(s) confirmed live on prod at the frozen SHA"
    refute_includes out, "would REFUSE"
  end

  def test_finalize_still_refuses_when_a_different_sha_is_deployed_on_top
    out = finalize_with(OTHER_DEPLOY_LIVE)

    assert_includes out, "would REFUSE: NOT confirmed live on prod: turf-monster @ 0988886"
    refute_includes out, "confirmed live on prod at the frozen SHA"
  end

  # Tripwire beside the behaviour above: the guard is the tolerant post-ship form,
  # and deploy_app's re-dispatch skip is the one caller left strict.
  def test_finalize_guard_is_the_post_ship_form_and_only_the_redispatch_skip_is_strict
    src = File.read(BIN)
    assert_includes src, 'deploy_live_verdict(g, ship_sha[g["repo"]], post_ship: true)'
    strict = src.scan(/^(?!def ).*deploy_live_verdict\((?:group|g), [^)]*\)/).reject { |c| c.include?("post_ship: true") }
    assert_equal ["  deploy_live_verdict(group, frozen)"], strict, "only deploy_already_live? keeps the strict read"
  end

  # --- the hub's run-list read ------------------------------------------------

  def runs_call(first_out:, first_ok:, mint:)
    setup = <<~RUBY
      CALLS = []
      def bounded_capture2e(*argv, env: nil, **_opts)
        CALLS << (env || {}).fetch("GH_TOKEN", "ambient")
        ok = CALLS.size == 1 ? #{first_ok} : true
        out = CALLS.size == 1 ? #{first_out.inspect} : #{JSON.generate([{ 'headSha' => FROZEN, 'status' => 'completed', 'conclusion' => 'success' }]).inspect}
        [out, Struct.new(:ok) { def success? = ok }.new(ok)]
      end
      module GhAuthRetry
        def self.mint(**) = #{mint.inspect}
      end
    RUBY
    run_cli([], setup: setup,
                call: 'r = deploy_workflow_runs("prod-deploy.yml", "/tmp"); puts("RUNS " + r.to_json); puts("CALLS " + CALLS.join(","))')
  end

  def test_a_credential_refusal_on_the_run_list_is_retried_with_a_minted_token
    out = runs_call(first_out: "GraphQL: Resource not accessible by integration", first_ok: false, mint: "fresh-lane")

    assert_includes out, "CALLS ambient,fresh-lane"
    assert_includes out, FROZEN, "the retried read returns the run at the frozen SHA"
  end

  def test_an_unreadable_run_list_is_nil_not_an_empty_list
    out = runs_call(first_out: "GraphQL: Resource not accessible by integration", first_ok: false, mint: nil)

    assert_includes out, "RUNS null", "unreadable is not 'read, and none'"
    assert_includes out, "CALLS ambient"
  end

  def test_the_hub_gap_names_an_unreadable_run_list
    setup = <<~RUBY
      def deploy_workflow_runs(_wf, _path) = nil
      def prod_up_ok?(_url) = true
      def origin_main_sha(_repo) = #{FROZEN.inspect}
    RUBY
    group = { "repo" => "mcritchie-studio", "kind" => "app",
              "prod_deploy" => { "strategy" => "github_actions", "workflow" => "prod-deploy.yml" } }
    out = run_cli([], setup: setup,
                      call: "puts('VERDICT ' + deploy_live_verdict(#{group.inspect}, #{FROZEN.inspect}, post_ship: true).inspect)")

    assert_match(/VERDICT \[false, .*gh run list` read itself failed/, out)
  end
end
