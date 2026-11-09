# frozen_string_literal: true

# .github/scripts/await-gem-propagation.sh end to end, with a stub `curl` on PATH.
# The incident (rel-20261109-900044): one fresh /info read printed "fully caught up"
# and bundler on the same runner missed the version 8s later. The script now passes
# only when every one of AWAIT_READS separate reads lists the version.
#
#   ruby -Itest test/lib/await_gem_propagation_script_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class AwaitGemPropagationScriptTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, ".github/scripts/await-gem-propagation.sh")
  VERSION = "0.141.0"

  # The stub answers each /info read from STUB_INFO (a comma list consumed in order,
  # the last entry repeating): `fresh` lists VERSION, `stale` lists only an older
  # version, `down` fails the read. A HEAD with -w (the .gem check) prints STUB_GEM.
  # A /versions read lists VERSION (the old script's second surface). Every call's
  # argv is appended to calls.log.
  STUB = <<~'SH'
    #!/usr/bin/env bash
    dir=$(dirname "$0")
    printf '%s\n' "$*" >> "$dir/calls.log"
    url="${@: -1}"
    case "$*" in
      *"-w %{http_code}"*) printf '%s' "${STUB_GEM:-200}"; exit 0 ;;
    esac
    case "$url" in
      */versions) printf 'studio-engine %s abc\n' "$STUB_VERSION"; exit 0 ;;
      */info/*)
        n=$(cat "$dir/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$dir/n"
        IFS=, read -ra seq <<< "$STUB_INFO"
        idx=$n; [ "$idx" -ge "${#seq[@]}" ] && idx=$(( ${#seq[@]} - 1 ))
        case "${seq[$idx]}" in
          fresh) printf -- '---\n0.140.0 |checksum:aa\n%s |checksum:bb\n' "$STUB_VERSION" ;;
          stale) printf -- '---\n0.140.0 |checksum:aa\n' ;;
          down)  exit 7 ;;
        esac
        exit 0 ;;
    esac
    exit 0
  SH

  def run_script(info:, gem: "200", timeout: 30, reads: 4, script: SCRIPT)
    Dir.mktmpdir("await-gem") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "curl"), STUB)
      File.chmod(0o755, File.join(bin, "curl"))
      lock = File.join(dir, "Gemfile.lock")
      File.write(lock, "GEM\n  specs:\n    studio-engine (#{VERSION})\n")
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "AWAIT_LOCK" => lock, "AWAIT_GEMS" => "studio-engine",
              "AWAIT_TIMEOUT" => timeout.to_s, "AWAIT_INTERVAL" => "0", "AWAIT_READS" => reads.to_s,
              "STUB_INFO" => info, "STUB_GEM" => gem, "STUB_VERSION" => VERSION }
      out, status = Open3.capture2e(env, "bash", script)
      calls = File.exist?(File.join(bin, "calls.log")) ? File.readlines(File.join(bin, "calls.log"), chomp: true) : []
      [out, status.exitstatus, calls]
    end
  end

  def info_reads(calls) = calls.count { |c| c.include?("/info/") }

  # [unit] REGRESSION, the incident: one fresh read, then stale reads. The old script
  # declared the edge caught up on that one read. The gem must not pass a poll in
  # which any read was stale; it passes on the first poll where all four are fresh.
  def test_one_fresh_read_among_stale_ones_does_not_pass
    out, code, calls = run_script(info: "fresh,stale,stale,stale,fresh")

    assert_equal 0, code, out
    refute_includes out, "fully caught up", "one fresh read is not proof: #{out}"
    assert_includes out, "awaiting studio-engine #{VERSION}: /info listed it on 1 of 4 connections (3 stale"
    assert_includes out, "is served: /info listed it on 4 of 4 separate connections and the .gem answered 200 (poll 2)"
    assert_equal 8, info_reads(calls), "two polls of four reads each"
  end

  # [unit] It reads what bundler 2.5.23 reads, the way bundler reads it: /info on the
  # index host over HTTP/1.1 with Gem::Net::HTTP's Accept-Encoding, one process (one
  # connection) per read, and the .gem download on rubygems.org.
  def test_reads_the_urls_and_headers_bundler_uses
    _out, code, calls = run_script(info: "fresh")

    assert_equal 0, code
    info = calls.select { |c| c.include?("/info/") }
    assert_equal 4, info.size, "AWAIT_READS separate curl processes, so separate connections"
    info.each do |c|
      assert_includes c, "https://index.rubygems.org/info/studio-engine"
      assert_includes c, "--http1.1"
      assert_includes c, "Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3"
      refute_match(/--range|-r /, c, "bundler's cold-cache /info read is a plain GET")
    end
    assert(calls.any? { |c| c.include?("https://rubygems.org/gems/studio-engine-#{VERSION}.gem") },
           "the .gem bundler downloads is checked: #{calls.inspect}")
  end

  # [unit] An old pin passes on the first poll: every lane runs this, so it must be cheap.
  def test_an_already_served_pin_passes_on_the_first_poll
    out, code, calls = run_script(info: "fresh")

    assert_equal 0, code
    assert_includes out, "(poll 1)"
    assert_equal 4, info_reads(calls)
  end

  # [unit] FAIL CLOSED on a proven miss: a body read without the version at the deadline
  # stops the job with a named cause instead of bundler's false "author removed it".
  def test_a_stale_read_at_the_deadline_fails_with_a_named_cause
    out, code, = run_script(info: "stale", timeout: 0)

    assert_equal 1, code, out
    assert_includes out, "::error::GEM_NOT_SERVED_ON_RUNNER: studio-engine #{VERSION}"
    assert_includes out, "0 of 4 connections (4 stale"
  end

  # [unit] The .gem is its own surface: /info fresh but the download 4xx is a proven miss.
  def test_a_missing_gem_file_is_a_proven_miss
    out, code, = run_script(info: "fresh", gem: "403", timeout: 0)

    assert_equal 1, code, out
    assert_includes out, ".gem missing (403)"
  end

  # [unit] Unreachable is not a proven miss: warn and let the install decide, since a
  # full bundler-cache hit needs no network.
  def test_unreachable_rubygems_warns_and_continues
    out, code, = run_script(info: "down", gem: "000", timeout: 0)

    assert_equal 0, code, out
    assert_includes out, "::warning::studio-engine #{VERSION}: RubyGems could not be read"
    refute_includes out, "GEM_NOT_SERVED_ON_RUNNER"
  end

  # [unit] A gem the lock does not pin is skipped, and a missing lock is a no-op.
  def test_an_unpinned_gem_reads_nothing
    Dir.mktmpdir do |dir|
      out, status = Open3.capture2e({ "AWAIT_LOCK" => File.join(dir, "nope.lock") }, "bash", SCRIPT)
      assert status.success?, out
    end
  end
end
