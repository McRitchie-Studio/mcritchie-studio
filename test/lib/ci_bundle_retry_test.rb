# frozen_string_literal: true

# Guard test for the CI RubyGems-propagation wait: no job installs gems before checking the
# versions are visible on the index this runner resolves through; `bundle install` otherwise
# dies exit 7 claiming the author "has removed" a live version. A WAIT, NOT A RETRY: a retry
# needs `continue-on-error: true`, which test/lib/ci_workflow_triggers_test.rb forbids. It runs
# ON THE RUNNER: a conductor-side check speaks only for its own CDN edge. INVARIANT over EVERY
# workflow: a `bundler-cache: true` step is IMMEDIATELY preceded by the await step. The final
# count assertion stops this passing by examining nothing.
# History: release rel-20260816-92c013.

require "minitest/autorun"
require "yaml"

class CiBundleRetryTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")
  AWAIT_SCRIPT = "await-gem-propagation.sh"

  def workflow_paths
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows found at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"
    paths
  end

  # Every step that INSTALLS gems, with the step before it, so a failure names
  # the exact site instead of just "somewhere in CI".
  def gem_installing_steps
    workflow_paths.flat_map do |path|
      doc = YAML.load_file(path, aliases: true) || {}
      (doc["jobs"] || {}).flat_map do |job_name, job|
        steps = (job || {})["steps"] || []
        steps.each_with_index.filter_map do |step, index|
          next unless step.is_a?(Hash)
          next unless step["uses"].to_s.start_with?("ruby/setup-ruby@")
          next unless (step["with"] || {})["bundler-cache"] == true

          {
            label: "#{File.basename(path)} job=#{job_name} step[#{index}]",
            previous: index.positive? ? steps[index - 1] : nil
          }
        end
      end
    end
  end

  def test_the_await_script_is_executable_and_fail_soft
    script = File.join(ROOT, ".github/scripts", AWAIT_SCRIPT)

    assert File.exist?(script), "#{script} is missing — every workflow step below invokes it"
    assert File.executable?(script), "#{script} is not executable, so `run:` will fail with permission denied"

    body = File.read(script)
    code = body.lines.reject { |l| l.strip.start_with?("#") }.join

    # POSITIVE form. The previous spelling of this guard refuted exactly
    # `/^\s*exit\s+1\b/` and nothing else, so `set -euo pipefail` and `exit 2`
    # both passed GREEN while being just as fatal — a guard that names one
    # spelling of a failure and calls the class closed. Assert the property
    # instead: EVERY exit in the script is exit 0, and errexit is never armed.
    exits = code.scan(/^\s*exit\s+(\S+)/).flatten
    refute_empty exits, "the await script has no explicit exit — it must end in an explicit `exit 0`"

    non_zero = exits.reject { |c| c == "0" }
    assert_empty non_zero,
                 "the await script must stay FAIL-SOFT and every exit must be `exit 0`; found #{non_zero.inspect}. " \
                 "It runs before the install in every job, so any hard exit turns a CDN hiccup into a brand-new " \
                 "way for CI to go red — the exact opposite of why it exists"

    # `set -e` (in any bundle: -e, -eu, -euo pipefail) makes the NEXT failing
    # command fatal without an `exit` line anywhere, which is how a fail-soft
    # script stops being fail-soft while still reading as one.
    set_flags = code.scan(/^\s*set\s+-([a-zA-Z]+)/).flatten
    errexit = set_flags.select { |f| f.include?("e") }
    assert_empty errexit,
                 "the await script must not arm errexit (`set -#{errexit.first}`): with it, any failing command " \
                 "aborts the step and fails the job, with no `exit` line for the check above to catch"
  end

  # The whole point of the wait is WHICH FILE it asks about. `/info/<gem>` is a
  # correlated proxy — the two files publish together — but bundler's "can no
  # longer be found" is raised from the resolver's version list, built from
  # `/versions`, and a stale `/versions` additionally makes bundler trust its
  # cached `/info` and skip re-fetching it. A script that polls only `/info` can
  # therefore read fresh while the install still fails, which is exactly what
  # shipped first. This pins the corrected mechanism so it cannot silently
  # regress to the proxy.
  def test_the_await_script_polls_the_versions_list_bundler_resolves_through
    body = File.read(File.join(ROOT, ".github/scripts", AWAIT_SCRIPT))
    code = body.lines.reject { |l| l.strip.start_with?("#") }.join

    assert_includes code, "index.rubygems.org/versions",
                    "the await script must consult /versions — it gates whether bundler re-fetches /info at all"

    assert_includes code, "index.rubygems.org/info/",
                    "the await script must consult /info — it SUPPLIES the versions the resolver enumerates " \
                    "(bundler 2.5.23: fetcher/compact_index.rb:30-47 -> parser.rb:43). A fresh /versions is " \
                    "necessary but NOT sufficient, and an earlier draft broke out on /versions alone"

    assert_match(/--range\s+"?-/, code,
                 "/versions is ~23MB, so it must be read with an HTTP range request on the tail; " \
                 "a full GET per job is not an acceptable cost")
  end

  # `curl … | grep -q` is a false-negative generator here, and it hides in
  # exactly the case this script exists for. `grep -q` exits on its FIRST match,
  # curl dies of EPIPE, and under `pipefail` that becomes the pipeline's status —
  # so a genuine hit reads as a miss. MEASURED against the live index: a match
  # early in the tail returned status 56, the same query for the LAST line
  # returned 0. A just-published version sits at the very end and lets curl
  # finish, so CI goes green while every older lookup silently misses.
  def test_the_await_script_never_pipes_curl_into_grep
    body = File.read(File.join(ROOT, ".github/scripts", AWAIT_SCRIPT))
    code = body.lines.reject { |l| l.strip.start_with?("#") }.join

    piped = code.lines.select { |l| l.include?("curl") && l.include?("|") && !l.include?("||") }
    assert_empty piped.map(&:strip),
                 "curl must not be piped (its output belongs in a command substitution): under `pipefail`, " \
                 "a downstream `grep -q` that exits early EPIPEs curl and turns a HIT into a MISS"

    refute_match(/grep\s+-[a-zA-Z]*q/, code,
                 "use `grep -c` (which reads the whole input) rather than `grep -q` (which short-circuits): " \
                 "the early exit is what EPIPEs curl and produces the false negative above")
  end

  def test_every_gem_installing_step_waits_for_propagation_first
    sites = gem_installing_steps

    sites.each do |site|
      previous = site[:previous]

      refute_nil previous,
                 "#{site[:label]}: nothing precedes this gem install, so nothing waits for the versions it needs"

      assert_includes previous["run"].to_s, AWAIT_SCRIPT,
                      "#{site[:label]}: the step immediately before a gem install must run #{AWAIT_SCRIPT}. " \
                      "A wait placed anywhere earlier in the job is not a wait for THIS install."
    end

    # Vacuity guard: a green here must mean "every site checked out", never
    # "there were no sites to check".
    assert_operator sites.length, :>=, 1,
                    "found no `bundler-cache: true` setup-ruby steps in #{WORKFLOW_GLOB} — " \
                    "either the workflows moved or the action was renamed, and this guard is now asserting nothing"
  end
end
