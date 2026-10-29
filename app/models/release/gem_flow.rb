require "rubygems"
require "json"

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
    # And it may never lock a BURNED version, wherever that sits. Once a later
    # version ships, a burned X is below main and the "above main" read passes it,
    # so the burn is recorded while it is still visible (newly_burned) and read
    # back here as a set.
    #
    #   locks   { consumer => { gem => locked version or nil } }
    #   shipped { gem => the version declared on its main, "" when unreadable }
    #   wanted  { gem => the version this release publishes or locks }
    #   burned  { gem => [versions recorded as burned] }
    #
    # An unreadable `main` version is no finding for the above-main read: that gem
    # is not checked out here, and the prerelease refusal and the ship's own gem
    # phase still stand. A burned version is a finding even then.
    def unshipped_final_findings(locks:, shipped:, wanted:, burned: {})
      locks.to_h.flat_map do |repo, gems|
        gems.to_h.filter_map do |gem_name, locked|
          locked = locked.to_s.strip
          next if locked.empty?

          if Array(burned.to_h[gem_name]).map { |v| v.to_s.strip }.include?(locked)
            next "#{repo} locks #{gem_name} #{locked}, a BURNED version (published by a prepare whose release " \
                 "never shipped it, then superseded)"
          end

          main = shipped.to_h[gem_name].to_s.strip
          next if main.empty?
          next unless newer?(locked, main)
          next if wanted.to_h[gem_name].to_s.strip == locked

          carried = wanted.to_h[gem_name].to_s.strip
          "#{repo} locks #{gem_name} #{locked}, a version past #{gem_name}'s main (#{main}) that " \
            "#{carried.empty? ? "this release does not carry" : "this release does not ship (it carries #{carried})"}"
        end
      end
    end

    # THE BURN RECORD. A final is burned the moment a newer version of its gem is
    # allocated past it before it ships: versions only move forward, so it can
    # never deploy. That moment is visible at prepare, where `published` (the v*
    # finals on the gem's tags) holds a version above the one on main and below
    # the one this release carries. An ejected gem burns nothing yet: the next
    # release may carry the same tree and reuse its final.
    #
    # Returns the versions to record, oldest first. An unreadable main records
    # nothing (the version window cannot be read).
    def newly_burned(published:, shipped:, carried:)
      shipped = shipped.to_s.strip
      carried = carried.to_s.strip
      return [] if shipped.empty? || carried.empty?

      Array(published).map { |v| v.to_s.strip.delete_prefix("v") }.uniq
                      .select { |v| newer?(v, shipped) && newer?(carried, v) }
                      .sort_by { |v| Gem::Version.new(v) }
    end

    # Recorded as an annotated tag in the gem repo, so every clone reads the same
    # set after a fetch. The prefix never matches the `v*` reads (allocation, the
    # stranded-work guard).
    BURNED_TAG_PREFIX = "burned-v"

    def burned_tag(version) = "#{BURNED_TAG_PREFIX}#{version}"

    # `git tag --list 'burned-v*'` output → the burned versions.
    def burned_versions(tag_lines)
      tag_lines.to_s.lines.map(&:strip).filter_map do |tag|
        tag.delete_prefix(BURNED_TAG_PREFIX) if tag.start_with?(BURNED_TAG_PREFIX) && tag.size > BURNED_TAG_PREFIX.size
      end
    end

    # `git ls-remote --tags origin 'refs/tags/burned-v*'` output → the burned
    # versions. An annotated tag lists twice (the tag and its peeled `^{}` commit).
    def burned_versions_from_ls_remote(out)
      names = out.to_s.lines.filter_map do |line|
        ref = line.split("\t", 2)[1].to_s.strip
        ref.delete_prefix("refs/tags/").delete_suffix("^{}") if ref.start_with?("refs/tags/")
      end
      burned_versions(names.uniq.join("\n"))
    end

    # `bin/release status`: one display line per registered gem naming its burned
    # versions. `reads` maps a gem to { versions:, source: } where source is
    # :origin (the record itself), :local (origin unreadable; the clone's tags as
    # of its last fetch, which can miss a newer burn) or :unreadable (neither).
    # An unread gem never prints as "none".
    def burned_status_lines(reads)
      reads.to_h.sort.map do |gem_name, read|
        read = read.to_h
        source = read[:source]
        next "#{gem_name}: cannot confirm its burned versions — neither origin nor the local clone answered" if source == :unreadable

        versions = Array(read[:versions]).map(&:to_s).uniq
                           .sort_by { |v| Gem::Version.correct?(v) ? Gem::Version.new(v) : Gem::Version.new("0") }
        where = source == :local ? " (local tags; origin unreadable, may miss a newer burn)" : ""
        if versions.empty?
          "#{gem_name}: no burned versions#{where}"
        else
          "BURNED #{gem_name} #{versions.join(', ')}#{where} — published, never shipped: no consumer may lock " \
            "#{versions.one? ? 'it' : 'them'}, and never yank"
        end
      end
    end

    # THE RUBYGEMS LISTING, read fail-closed. /api/v1/versions/<gem>.json answers
    # 200 with the live versions (yanked ones are absent), or 404 for a gem never
    # published. Anything else (a timeout, a 5xx, a body that is not a JSON list)
    # is unreadable, never empty: an empty read sends prepare to publish a version
    # RubyGems already holds, and RubyGems' refusal then reads as a yank.
    class ListingUnreadable < StandardError; end

    LISTING_UNREADABLE = "RubyGems listing unreadable"

    def listing(code, body)
      code = code.to_s.strip
      return [] if code == "404"
      raise ListingUnreadable, "HTTP #{code.empty? ? "none" : code}" unless code == "200"

      parsed = JSON.parse(body.to_s)
      raise ListingUnreadable, "the body is not a list of versions" unless parsed.is_a?(Array)

      parsed
    rescue JSON::ParserError
      raise ListingUnreadable, "the body is not JSON"
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
