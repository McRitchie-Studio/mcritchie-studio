# frozen_string_literal: true

require "yaml"

class Release
  # WHICH CI JOBS OF A CONSUMER BUNDLE WITHOUT THE RUNNER-SIDE PROPAGATION WAIT.
  # IO-free and Rails-free: bin/release require_relative's it and hands it the text of
  # a consumer's .github/workflows/*.yml files.
  #
  # WHY (task release-prepare-night-lessons). A gem publish has two waits. The
  # conductor holds the lock push until the RubyGems CDN serves the version
  # (await_published_gems!), and each consumer's CI holds `bundle install` until ITS
  # runner's CDN edge serves it (.github/scripts/await-gem-propagation.sh, run by the
  # hub's reusable-ci.yml with `await-gem-propagation: true`, or by a repo's own copy).
  # The conductor cannot see a runner's edge, so the runner wait is the one that
  # closes the race. On rel-20261110-208612 voicebox's scan_ruby lost it: voicebox's
  # CI is the stock Rails workflow, its jobs bundle in `ruby/setup-ruby` with
  # `bundler-cache: true`, and none of them runs the runner wait. Nothing said so
  # before the lock bump. This names those jobs at the bump, so the operator knows
  # which red to expect and which repo's CI owes the step.
  module RunnerGemWait
    module_function

    SCRIPT = "await-gem-propagation"
    REUSABLE_CI = "reusable-ci.yml"
    AWAIT_INPUT = "await-gem-propagation"

    # PURE. { path => yaml text } → ["<file>: <job>", …] for every job that bundles
    # with no runner wait before it. A file that does not parse is skipped, never
    # guessed at.
    def unguarded_jobs(workflows)
      workflows.flat_map do |path, text|
        jobs = parse_jobs(text)
        jobs.filter_map { |name, job| "#{File.basename(path.to_s)}: #{name}" unless guarded?(job) }
      end
    end

    # PURE. A job is guarded when it calls the hub's reusable CI with the wait input
    # on, or when a step that runs the wait script comes before its first bundling
    # step. A job that never bundles needs no wait.
    def guarded?(job)
      return true unless job.is_a?(Hash)

      uses = job["uses"].to_s
      return truthy?((job["with"] || {})[AWAIT_INPUT]) if uses.include?(REUSABLE_CI)

      steps = Array(job["steps"])
      first_bundle = steps.index { |step| bundles?(step) }
      return true if first_bundle.nil?

      steps.first(first_bundle).any? { |step| step.is_a?(Hash) && step["run"].to_s.include?(SCRIPT) }
    end

    # PURE. Does this step run `bundle install`? setup-ruby with bundler-cache on, or
    # a run line that installs.
    def bundles?(step)
      return false unless step.is_a?(Hash)
      return truthy?((step["with"] || {})["bundler-cache"]) if step["uses"].to_s.start_with?("ruby/setup-ruby")

      step["run"].to_s.match?(/\bbundle(?:\s+install\b|\s*$)/)
    end

    # PURE. The warning line for one consumer, or nil when every job is guarded.
    def warning(repo, jobs)
      return nil if jobs.empty?

      "⚠ #{repo}: CI bundles without the runner wait (#{jobs.join(', ')}). A runner whose CDN edge is " \
        "still stale reds it with \"can no longer be found in that source\" although the lock is right. " \
        "Add .github/scripts/#{SCRIPT}.sh before each bundle, or call the hub's #{REUSABLE_CI} with " \
        "`#{AWAIT_INPUT}: true`."
    end

    def parse_jobs(text)
      doc = YAML.safe_load(text.to_s, aliases: true)
      doc.is_a?(Hash) && doc["jobs"].is_a?(Hash) ? doc["jobs"] : {}
    rescue Psych::Exception
      {}
    end

    def truthy?(value) = value == true || value.to_s == "true"
  end
end
