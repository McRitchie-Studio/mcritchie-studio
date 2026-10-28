require "rubygems"

class Release
  # WHICH GEM FLOW A RELEASE RUNS, and the decisions that differ between them.
  # Design: docs/agents/system/gem-release-flow.md.
  #
  #   :final      (the default) `bin/release prepare` publishes the final x.y.z and
  #               tags it v<x.y.z>; consumers lock it before the pre-QA gate; the ship
  #               finds it live, re-locks nothing, and deploys the SHAs QA gated.
  #   :candidate  the older flow, kept for one release as a rollback lever
  #               (RELEASE_GEM_FLOW=candidate): prepare publishes x.y.z.rcN and the
  #               ship publishes the final, re-locks every consumer and reads CI again.
  #
  # Decisions only; bin/release.rb supplies every RubyGems and git read.
  module GemFlow
    module_function

    MODES = %i[final candidate].freeze
    ENV_KEY = "RELEASE_GEM_FLOW"

    # The flow named by the environment. Anything but "candidate" is the default:
    # a typo must not quietly restore the slower flow, and it cannot select an
    # unknown one.
    def mode(env = ENV)
      env[ENV_KEY].to_s.strip.downcase == "candidate" ? :candidate : :final
    end

    def final?(env = ENV) = mode(env) == :final

    Action = Struct.new(:action, :version, :reason, keyword_init: true) do
      def final_live? = action == :final_live
      def publish? = action == :publish
    end

    # Prepare's act for one gem under the :final flow. `live` is the RubyGems
    # listing. A live final is reused: phase 0 allocation and the stranded-work
    # guard, both reading the v* tag, have already refused or re-allocated any tip
    # that moved past it, so a live final here was built from this tree.
    def prepare_action(final:, live:)
      final = final.to_s.strip
      numbers = Array(live).map { |e| (e.is_a?(Hash) ? (e["number"] || e[:number]) : e).to_s.strip }
      if numbers.include?(final)
        Action.new(action: :final_live, version: final,
                   reason: "#{final} is already live on RubyGems and tagged at this tree; consumers lock it again")
      else
        Action.new(action: :publish, version: final, reason: "publish #{final} now, before the pre-QA gate")
      end
    end

    # AN UNSHIPPED FINAL NOBODY IS SHIPPING. Under the :final flow a QA-red release
    # can leave consumers locked to a published final whose gem then leaves the
    # release (its member ejected). The prerelease refusal cannot see it: the lock
    # names an ordinary version. A consumer may lock a registered gem ABOVE the
    # version on that gem's `main` (the last one shipped) only when this release
    # carries the gem at exactly that version.
    #
    #   locks   { consumer => { gem => locked version or nil } }
    #   shipped { gem => the version declared on its main, "" when unreadable }
    #   wanted  { gem => the version this release publishes or locks }
    #
    # An unreadable `main` version is no finding: that gem is not checked out here,
    # and the prerelease refusal and the ship's own gem phase still stand.
    def unshipped_final_findings(locks:, shipped:, wanted:)
      locks.to_h.flat_map do |repo, gems|
        gems.to_h.filter_map do |gem_name, locked|
          locked = locked.to_s.strip
          main   = shipped.to_h[gem_name].to_s.strip
          next if locked.empty? || main.empty?
          next unless newer?(locked, main)
          next if wanted.to_h[gem_name].to_s.strip == locked

          carried = wanted.to_h[gem_name].to_s.strip
          "#{repo} locks #{gem_name} #{locked}, a version past #{gem_name}'s main (#{main}) that " \
            "#{carried.empty? ? "this release does not carry" : "this release does not ship (it carries #{carried})"}"
        end
      end
    end

    UNSHIPPED_FINAL_REMEDY =
      "That version was published by a prepare whose release did not ship it, and it must not reach production " \
      "unreviewed. Either put the gem's task back on this release, or land a task on the consumer's `accepted` " \
      "that runs `bundle lock --update <gem> --conservative` to the version on the gem's main; then re-run " \
      "`bin/release prepare`. Do not yank it: a yank frees no number and breaks every lock that names it " \
      "(docs/agents/system/gem-release-flow.md)."

    def newer?(a, b)
      Gem::Version.new(a) > Gem::Version.new(b)
    rescue ArgumentError
      false
    end
  end
end
