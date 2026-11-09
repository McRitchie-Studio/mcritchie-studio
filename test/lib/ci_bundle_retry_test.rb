# frozen_string_literal: true

# Guard test for the CI RubyGems-propagation wait: no job installs gems before checking the
# versions are served to this runner the way bundler reads them; `bundle install` otherwise
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

  # FAIL CLOSED ONLY ON A PROVEN MISS. The script may exit 1 (GEM_NOT_SERVED_ON_RUNNER,
  # a body read without the version at the deadline) and nothing else: no other code,
  # and no errexit, because `set -e` makes ANY failing command (a curl timeout, a grep
  # with no match) fatal with no `exit` line for this guard to read. An unreachable
  # RubyGems still exits 0. Behaviour: test/lib/await_gem_propagation_script_test.rb.
  def test_the_await_script_is_executable_and_fails_only_on_a_proven_miss
    script = File.join(ROOT, ".github/scripts", AWAIT_SCRIPT)

    assert File.exist?(script), "#{script} is missing — every workflow step below invokes it"
    assert File.executable?(script), "#{script} is not executable, so `run:` will fail with permission denied"

    code = File.read(script).lines.reject { |l| l.strip.start_with?("#") }.join

    exits = code.scan(/^\s*exit\s+(\S+)/).flatten
    refute_empty exits, "the await script has no explicit exit — it must end in an explicit `exit 0`"
    assert_empty exits - %w[0 1], "the await script exits 0, or 1 on a proven miss; found #{exits.inspect}"
    assert_equal 1, exits.count("1"), "exactly one hard exit: the GEM_NOT_SERVED_ON_RUNNER refusal"
    assert_match(/GEM_NOT_SERVED_ON_RUNNER[^\n]*\n\s*exit 1/, code, "the one `exit 1` is the named refusal")

    set_flags = code.scan(/^\s*set\s+-([a-zA-Z]+)/).flatten
    errexit = set_flags.select { |f| f.include?("e") }
    assert_empty errexit,
                 "the await script must not arm errexit (`set -#{errexit.first}`): with it, any failing command " \
                 "aborts the step and fails the job, with no `exit` line for the check above to catch"
  end

  # WHICH FILE, AND HOW. Bundler 2.5.23 on a runner's cold cache always re-fetches
  # `/info/<gem>` (compact_index_client/cache.rb `info`), and that body SUPPLIES the
  # versions the resolver enumerates. So the script reads /info on the index host, on
  # several separate connections: one read proved nothing in rel-20261109-900044.
  def test_the_await_script_reads_info_on_several_connections_and_the_gem
    code = File.read(File.join(ROOT, ".github/scripts", AWAIT_SCRIPT)).lines.reject { |l| l.strip.start_with?("#") }.join

    assert_includes code, "index.rubygems.org", "bundler reads the compact index from index.rubygems.org"
    assert_includes code, "/info/", "the await script must read /info — it SUPPLIES the versions bundler resolves"
    assert_includes code, "/gems/", "the await script must check the .gem bundler downloads"
    assert_match(/READS=\$\{AWAIT_READS:-([2-9]|\d\d+)\}/, code, "more than one read per poll: one read proves nothing")
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
