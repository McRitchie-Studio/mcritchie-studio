# frozen_string_literal: true

# [unit] The lock-bump CI race of rel-20261110-208612: voicebox scan_ruby (run 42781359873)
# was told studio-engine 0.143.0 was "removed" seconds after the lock push. Two gaps:
#   1. the conductor read /info with one plain curl; bundler reads the gzip copy on
#      several connections;
#   2. voicebox's stock Rails CI runs no runner-side wait, and nothing said so.
# History: task release-prepare-night-lessons.
require_relative "release_cli_harness"
require_relative "../../app/models/release/runner_gem_wait"

class ReleaseGemRunnerWaitTest < ReleaseCliHarness
  FRESH = "---\n0.142.0 |checksum:aa\n0.143.0 |checksum:bb\n"
  STALE = "---\n0.142.0 |checksum:aa\n"

  # The real gem_version_miss with only Open3 stood in: /info answers fresh on the
  # first connection and stale on the rest. Every /info read is printed.
  def probe(info_bodies)
    setup = <<~RUBY
      ENV.delete("RELEASE_GEM_INDEXED")
      Object.send(:remove_const, :GEM_INFO_READS)
      GEM_INFO_READS = 8
      INFO_BODIES = #{info_bodies.inspect}
      $info_reads = 0
      OK = Struct.new(:ok) { def success? = ok }
      module Open3
        def self.capture2e(*argv, **)
          url = argv.last.to_s
          if url.include?("/info/")
            puts("INFO-READ " + argv.join(" "))
            body = INFO_BODIES[$info_reads] || INFO_BODIES.last
            $info_reads += 1
            return [body, OK.new(true)]
          end
          return ["studio-engine 0.143.0 abc\\n", OK.new(true)] if url.end_with?("/versions")
          ["", OK.new(true)]
        end
      end
    RUBY
    run_cli([], setup: setup, call: %(puts("MISS=" + gem_version_miss("studio-engine", "0.143.0").inspect)))
  end

  def test_one_fresh_connection_among_stale_ones_is_a_miss_on_info
    out = probe([FRESH] + [STALE] * 7)

    assert_includes out, 'MISS="/info"', out
    assert_equal 8, out.scan("INFO-READ").size, "one poll makes eight separate reads"
    out.lines.grep(/INFO-READ/).each do |line|
      assert_includes line, "Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3", "read as bundler reads"
      assert_includes line, "--compressed"
    end
  end

  def test_every_connection_fresh_is_served
    out = probe([FRESH])

    assert_includes out, "MISS=nil", out
  end

  # --- the runner wait each consumer's CI does or does not run ----------------

  # voicebox's ci.yml, abridged to the shape that lost the race: the stock Rails jobs.
  STOCK_RAILS_CI = <<~YAML
    name: CI
    on:
      pull_request:
    jobs:
      scan_ruby:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v6
          - uses: ruby/setup-ruby@v1
            with:
              bundler-cache: true
          - run: bin/brakeman --no-pager
      lint:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v6
          - uses: ruby/setup-ruby@v1
            with:
              bundler-cache: true
          - run: bin/rubocop -f github
      no_ruby:
        runs-on: ubuntu-latest
        steps:
          - run: echo hi
  YAML

  REUSABLE_CALLER = <<~YAML
    jobs:
      ci:
        uses: McRitchie-Studio/mcritchie-studio/.github/workflows/reusable-ci.yml@main
        with:
          await-gem-propagation: true
  YAML

  OWN_COPY = <<~YAML
    jobs:
      test:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v6
          - run: .github/scripts/await-gem-propagation.sh
          - uses: ruby/setup-ruby@v1
            with:
              bundler-cache: true
  YAML

  def test_the_stock_rails_jobs_are_named_as_unguarded
    jobs = Release::RunnerGemWait.unguarded_jobs("/w/voicebox/.github/workflows/ci.yml" => STOCK_RAILS_CI)

    assert_equal ["ci.yml: scan_ruby", "ci.yml: lint"], jobs
    line = Release::RunnerGemWait.warning("voicebox", jobs)
    assert_includes line, "voicebox"
    assert_includes line, "ci.yml: scan_ruby"
    assert_includes line, "await-gem-propagation: true"
  end

  def test_a_reusable_ci_caller_with_the_wait_and_a_repo_copy_are_guarded
    assert_empty Release::RunnerGemWait.unguarded_jobs("a.yml" => REUSABLE_CALLER, "b.yml" => OWN_COPY)
    assert_nil Release::RunnerGemWait.warning("alex-build", [])
  end

  # The control: the same caller with the wait input off is named.
  def test_control_a_reusable_ci_caller_without_the_wait_is_named
    off = REUSABLE_CALLER.sub("await-gem-propagation: true", "await-gem-propagation: false")

    assert_equal ["ci.yml: ci"], Release::RunnerGemWait.unguarded_jobs("ci.yml" => off)
  end

  def test_a_wait_after_the_bundle_does_not_count
    late = OWN_COPY.sub("      - run: .github/scripts/await-gem-propagation.sh\n", "") +
           "      - run: .github/scripts/await-gem-propagation.sh\n"

    assert_equal ["c.yml: test"], Release::RunnerGemWait.unguarded_jobs("c.yml" => late)
  end

  def test_a_workflow_that_does_not_parse_is_skipped
    assert_empty Release::RunnerGemWait.unguarded_jobs("bad.yml" => "jobs: [\n")
  end
end
