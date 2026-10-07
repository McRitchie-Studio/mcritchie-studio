# frozen_string_literal: true

# bin/release.rb's publish → SERVED → INSTALLED wait, the half that makes prepare
# install each published gem on THIS machine before anything reads it. Standalone:
#   ruby -Itest test/lib/release_cli_gem_install_test.rb
#
# THE INCIDENT, rel-20261007-f8453b (2026-10-07). solana-studio 0.12.3 was already
# live, so an idempotent re-run skipped its publish; studio-engine's lock pinned it,
# and studio-engine's `bin/release-check --build` died at boot with
# `Could not find solana-studio-0.12.3 in locally installed gems`. The operator
# installed it by hand. The CDN half of the wait (release_cli_gem_await_test.rb)
# already existed and passed; nothing installed the gem.
#
# A FILE OF ITS OWN: the release CLI files are frozen at their size by
# config/test_health.yml. It subclasses the shared harness, and every case drives
# the REAL script with `sh`, `curl` and the publish stubbed, so no test reaches
# RubyGems or publishes anything.
require_relative "release_cli_harness"

class ReleaseCliGemInstallTest < ReleaseCliHarness
  # Load the real script with the wait's seams set BEFORE load (the poll constants
  # are read at load time), run `setup` (method stubs), then `call`. An abort! is
  # caught in-process and printed as "REFUSED: <message>".
  def drive(call, setup: "", env: {}, argv: ["--help"])
    seams = { "RELEASE_GEM_POLL_INTERVAL" => "0", "RELEASE_GEM_POLL_TIMEOUT" => "0",
              "RELEASE_GEM_INDEXED" => "yes", "RELEASE_GEM_INSTALLED" => "yes" }.merge(env)
    run_ruby(<<~RUBY)
      ENV.update(#{seams.inspect})
      ARGV.replace(#{argv.inspect})
      begin; load #{BIN.inspect}; rescue SystemExit; end
      def sleep(_seconds) = nil
      #{setup}
      begin
        #{call}
      rescue SystemExit => e
        puts "REFUSED: " + e.message.to_s
      end
    RUBY
  end

  # Records every `sh` the wait makes and answers from a queue of exit verdicts
  # (true when the queue runs dry). The mise ruby is pinned to a fake bin dir, so
  # the install must reach two gem homes.
  STUB_SH = <<~RUBY
    $sh_calls = []
    $sh_answers = []
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      $sh_calls << { cmd: cmd, path: (env || {})["PATH"].to_s }
      ok = $sh_answers.empty? ? true : $sh_answers.shift
      ["", ok]
    end
    def gate_ruby_bin_dir = "/fake/mise/ruby/bin"
  RUBY

  # ── [unit] the publish wait polls the compact index until the version appears ──

  # The real index check, with curl stubbed at Open3: two reads that lack 0.12.3,
  # then one that lists it, and the .gem artifact answering 200. The wait must poll
  # exactly three times and then proceed — not give up early, not bump on a prefix.
  def test_the_wait_polls_the_compact_index_until_the_version_appears
    setup = <<~RUBY
      $index_reads = 0
      $bodies = [
        "0.12.2 ed25519:~> 1.3|checksum:aaa\\n",
        "0.12.2 ed25519:~> 1.3|checksum:aaa\\n0.12 ed25519:~> 1.3|checksum:ccc\\n",
        "0.12.2 ed25519:~> 1.3|checksum:aaa\\n0.12.3 ed25519:~> 1.3|checksum:bbb\\n"
      ]
      ok = Struct.new(:ok) { def success? = ok }
      Open3.define_singleton_method(:capture2e) do |*cmd|
        url = cmd.last
        if url.include?("index.rubygems.org/info/solana-studio")
          $index_reads += 1
          [$bodies.shift || "", ok.new(true)]
        elsif url.end_with?("/gems/solana-studio-0.12.3.gem")
          ["", ok.new(true)]
        else
          ["", ok.new(false)]
        end
      end
    RUBY
    out = drive(%(await_published_gems!("solana-studio" => "0.12.3"); puts "READS=" + $index_reads.to_s; puts "PROCEEDED"),
                setup: setup, env: { "RELEASE_GEM_INDEXED" => "", "RELEASE_GEM_POLL_TIMEOUT" => "60" })

    assert_includes out, "PROCEEDED", out
    assert_includes out, "READS=3", "it must keep polling past a stale read and a prefix match: #{out}"
    assert_match(/solana-studio 0\.12\.3 is on the index/, out)
    refute_includes out, "REFUSED"
  end

  # Listed on the index is not served: bundler downloads the .gem next, and that is a
  # separate CDN object. An index hit with a missing artifact must keep waiting, and
  # refuse at the bound.
  def test_an_indexed_version_whose_gem_file_is_not_served_is_not_ready
    setup = <<~RUBY
      ok = Struct.new(:ok) { def success? = ok }
      Open3.define_singleton_method(:capture2e) do |*cmd|
        if cmd.last.include?("index.rubygems.org/info/")
          ["0.12.3 ed25519:~> 1.3|checksum:bbb\\n", ok.new(true)]
        else
          ["", ok.new(false)]
        end
      end
    RUBY
    out = drive(%(await_published_gems!("solana-studio" => "0.12.3"); puts "PROCEEDED"),
                setup: setup, env: { "RELEASE_GEM_INDEXED" => "" })

    assert_match(/REFUSED: .*still not serving it/, out)
    refute_includes out, "PROCEEDED"
  end

  def test_the_index_parser_matches_a_whole_version_never_a_prefix
    body = "0.47.2 a:~> 1|checksum:x\n0.48.0 a:~> 1|checksum:y\n"
    out = eval_helper(%([gem_index_lists?(#{body.inspect}, "0.48.0"), gem_index_lists?(#{body.inspect}, "0.4"), ) +
                      %(gem_index_lists?(#{body.inspect}, "0.49.0"), gem_index_lists?("", "0.48.0")].inspect))

    assert_equal "[true, false, false, false]", out
  end

  # ── [unit] the local install ──────────────────────────────────────────────────

  # Both gem homes: the shell ruby (publish_gem's release-check and `gem build`) and
  # mise's pinned ruby (the gate suites). A gem in one is invisible to the other.
  def test_it_installs_the_published_version_into_every_ruby_the_sweep_spawns
    out = drive(%(await_published_gems!("solana-studio" => "0.12.3"); puts JSON.generate($sh_calls)),
                setup: STUB_SH, env: { "RELEASE_GEM_INSTALLED" => "" })
    calls = JSON.parse(out.lines.last)

    expected = %w[gem install solana-studio -v 0.12.3 --conservative --no-document]
    assert_equal [expected, expected], calls.map { |c| c["cmd"] }, out
    assert_equal "", calls[0]["path"], "the first install must run under the shell ruby, with no overlay"
    assert calls[1]["path"].start_with?("/fake/mise/ruby/bin#{File::PATH_SEPARATOR}"),
           "the second must lead PATH with mise's ruby: #{calls[1].inspect}"
    assert_match(/solana-studio 0\.12\.3 is installed locally/, out)
  end

  def test_a_failed_install_is_retried_within_the_bound
    out = drive(%($sh_answers = [false]; await_published_gems!("studio-engine" => "0.92.2"); puts "CALLS=" + $sh_calls.size.to_s),
                setup: STUB_SH, env: { "RELEASE_GEM_INSTALLED" => "", "RELEASE_GEM_POLL_TIMEOUT" => "60" })

    refute_includes out, "REFUSED"
    assert_includes out, "CALLS=3", "one failed shell install, then both homes again: #{out}"
  end

  def test_an_install_that_never_succeeds_refuses_with_the_manual_remedy
    out = drive(%(await_published_gems!("studio-engine" => "0.92.2"); puts "PROCEEDED"),
                env: { "RELEASE_GEM_INSTALLED" => "no" })

    refute_includes out, "PROCEEDED"
    assert_match(/REFUSED: .*gem install studio-engine -v 0\.92\.2.*still fails on this machine/, out)
    assert_match(/NOTHING was bumped/, out, "the operator must know a re-run is safe")
    assert_match(/mise x ruby@\d+\.\d+\.\d+ -- gem install studio-engine -v 0\.92\.2/, out,
                 "and the remedy must name the second gem home")
  end

  # The bump calls the wait again for gems the publish loop already readied; that
  # second call must be a lookup, not a second round of installs.
  def test_a_gem_already_readied_is_not_installed_twice
    call = <<~RUBY
      await_published_gems!("solana-studio" => "0.12.3")
      await_published_gems!("solana-studio" => "0.12.3")
      puts "CALLS=" + $sh_calls.size.to_s
    RUBY
    out = drive(call, setup: STUB_SH, env: { "RELEASE_GEM_INSTALLED" => "" })

    assert_includes out, "CALLS=2", out
  end

  # ── [integration] prepare bumps no consumer lock before the gem resolves locally ──

  # Driven through the real bump. The install seam says NO, so the wait must refuse
  # before the bump's first git or bundler call — `sh` records that nothing ran.
  def test_the_consumer_lock_bump_never_starts_while_the_gem_is_not_installed
    call = <<~RUBY
      bump_consumer_locks_for_qa([{ "repo" => "turf-monster" }], { "solana-studio" => "0.12.3" })
      puts "COMMITTED"
    RUBY
    out = drive(call, setup: STUB_SH + %(\nat_exit { puts "SH=" + JSON.generate($sh_calls) }),
                env: { "RELEASE_GEM_INSTALLED" => "no" })

    assert_match(/REFUSED: .*still fails on this machine/, out)
    refute_includes out, "COMMITTED"
    assert_includes out, "SH=[]", "no git fetch, bundle lock or commit may run before the install succeeds: #{out}"
  end

  # The incident, end to end through the real publish loop: an ALREADY-LIVE
  # solana-studio, then studio-engine to publish. solana-studio must be installed
  # BEFORE studio-engine's release-check runs; and if it cannot be, studio-engine
  # must never publish.
  PUBLISH_STUBS = <<~RUBY
    $events = []
    def checkout_detached(repo, _sha) = $events << "checkout " + repo
    def restore_gem_primary(repo) = $events << "restore " + repo
    def publish_gem(repo, version) = $events << "publish " + repo + " " + version
    def install_published_gem(gem_name, version)
      $events << "install " + gem_name + " " + version
      ENV["RELEASE_GEM_INSTALLED"] != "no"
    end
  RUBY

  PLAN = %([{ "repo" => "solana-studio", "version" => "0.12.3", "already_live" => true, "tip" => "f326214" },
            { "repo" => "studio-engine", "version" => "0.92.2", "already_live" => false, "tip" => "cd37a71" }])

  def test_an_already_live_upstream_gem_is_installed_before_the_next_gem_publishes
    out = drive(%(p = publish_gems_for_qa(#{PLAN}); puts JSON.generate($events); puts JSON.generate(p)),
                setup: PUBLISH_STUBS)
    events, published = out.lines.last(2).map { |l| JSON.parse(l) }

    assert_equal ["install solana-studio 0.12.3", "checkout studio-engine", "publish studio-engine 0.92.2",
                  "restore studio-engine", "install studio-engine 0.92.2"], events, out
    assert_equal({ "solana-studio" => "0.12.3", "studio-engine" => "0.92.2" }, published)
  end

  def test_a_gem_that_cannot_be_installed_stops_the_next_publish
    out = drive(%(publish_gems_for_qa(#{PLAN}); puts "PUBLISHED_ALL"),
                setup: PUBLISH_STUBS + %(\nat_exit { puts "EVENTS=" + JSON.generate($events) }),
                env: { "RELEASE_GEM_INSTALLED" => "no" })

    assert_match(/REFUSED: .*solana-studio 0\.12\.3/, out)
    refute_includes out, "PUBLISHED_ALL"
    assert_includes out, %(EVENTS=["install solana-studio 0.12.3"]),
                    "studio-engine must not be checked out or published: #{out}"
  end

  # THE CONTROL: a dry run previews the publish and must neither install nor wait.
  def test_a_dry_run_installs_nothing
    out = drive(%(publish_gems_for_qa([{ "repo" => "studio-engine", "version" => "", "dry" => true }]); ) +
                %(puts "EVENTS=" + JSON.generate($events)),
                setup: PUBLISH_STUBS, argv: ["--dry-run"], env: { "RELEASE_GEM_INSTALLED" => "no" })

    assert_includes out, "EVENTS=[]", out
    refute_includes out, "REFUSED"
  end
end
