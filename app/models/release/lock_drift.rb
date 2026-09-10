class Release
  # Does any repo in the ecosystem resolve a just-published gem OLDER than the
  # version that was published? The post-condition `bin/release prepare` asserts
  # after it has bumped every lock it is responsible for.
  #
  # Deliberately IO-free — no git, no bundle, no File — exactly like
  # Release::GemfileRepin. It takes a resolution MAP in and returns findings out,
  # so the shell wiring that reads each Gemfile.lock lives in bin/release.rb and
  # this stays trivially unit-testable. Reading a lock is
  # Release::ShipSequence.locked_version's job; this module never parses one.
  #
  # WHY THIS EXISTS. `bump_consumer_locks_for_qa` bumps the locks of the release's
  # APP members. studio-engine is registered as a `gem` — a PRODUCER — so it never
  # entered that loop, even though its own Gemfile declares `solana-studio` and it
  # is therefore a consumer too. Every solana-studio publish left the engine's lock
  # behind, and the engine's own consumer-ci lane (`bin/gem-drift-check`, in
  # studio-engine) then reddened EVERY open engine PR over a line no PR author
  # owns. Measured 2026-09-09: engine lock at solana-studio 0.9.0, published 0.9.1,
  # PRs #313 and #245 both red on `Check this engine does not trail turf_monster`.
  # bump_producer_locks_for_accepted closes the hole; this asserts that it did.
  #
  # ── THE FLOOR IS THE PUBLISHED VERSION, AND AHEAD IS NEVER A FAILURE ──────────
  #
  # A repo TRAILS when it resolves a published gem STRICTLY OLDER than the version
  # the sweep just published. A repo resolving something NEWER is not a finding.
  #
  # That asymmetry is the whole design, so it is worth stating why the symmetric
  # phrasing ("no repo resolves older than any OTHER repo resolves") is not what
  # is implemented. Take the max RESOLVED version as the floor instead, and a
  # producer legitimately sitting ahead — studio-engine developing against an
  # unreleased solana-studio, via a path: or git: checkout — instantly makes every
  # correctly-bumped consumer "trail" it. The guard would fire on repos that are
  # exactly where the sweep just put them. studio-engine/bin/gem-drift-check
  # reaches the same conclusion from the other side and says so in the same words:
  # "Engine ahead is fine (it is the producer; it may test against an unreleased
  # gem)."
  #
  # The published version IS the common anchor — every repo is measured against
  # the same number, so no repo can be behind another without being behind the
  # anchor first. It is supplied by the sweep that just ran, never written down
  # here: there is no version literal in this file or its test, and the next
  # publish re-anchors the guard without anyone editing it. That is the point. A
  # test asserting `>= 0.9.1` would be a number that goes stale at the next push,
  # which is the exact defect class this guard is built not to be.
  module LockDrift
    module_function

    # Repos resolving a published gem older than the published version.
    #
    #   resolutions — { repo => { gem_name => resolved_version_or_nil } }
    #                 nil (or a missing key) means the repo does not bundle that
    #                 gem at all, which is a SKIP and never a finding: most repos
    #                 legitimately declare neither gem.
    #   published   — { gem_name => published_version } from the sweep's own
    #                 publish map. A gem with a blank version is skipped whole —
    #                 an unknown anchor cannot prove anyone is behind it.
    #
    # Returns an array of finding hashes, ordered by repo then gem so the message
    # is stable run to run. Empty means the ecosystem is aligned.
    def trailing(resolutions, published)
      findings = []

      published.to_h.each do |gem_name, published_version|
        anchor = version_or_nil(published_version)
        next if anchor.nil?

        resolutions.to_h.each do |repo, gems|
          resolved = version_or_nil(gems.to_h[gem_name] || gems.to_h[gem_name.to_s])
          next if resolved.nil?
          next unless resolved < anchor

          findings << {
            "repo" => repo.to_s,
            "gem" => gem_name.to_s,
            "resolved" => resolved.to_s,
            "published" => anchor.to_s
          }
        end
      end

      findings.sort_by { |f| [ f["repo"], f["gem"] ] }
    end

    # True when nothing trails — the sentence the sweep wants to be able to say.
    def aligned?(resolutions, published)
      trailing(resolutions, published).empty?
    end

    # The abort text for a set of findings. Names every trailing repo with both
    # numbers, then the remedy, because the operator reading this is mid-sweep
    # with gems already pushed and needs to know that the publish is NOT the thing
    # to retry.
    def message(findings)
      rows = Array(findings).map do |f|
        "#{f['repo']} resolves #{f['gem']} #{f['resolved']}, published #{f['published']}"
      end

      "lock drift after the sweep's own bumps — #{rows.join('; ')}. A repo left behind a gem this " \
        "sweep published reddens every open PR in that repo (studio-engine's consumer-ci lane fails " \
        "on exactly this), and it does not self-correct. The gems are ALREADY PUBLISHED and must not " \
        "be re-pushed: fix the lock in the named repo (`bundle update <gem>` on `accepted`), then " \
        "re-run `bin/release prepare` — it resumes."
    end

    # --- internals -------------------------------------------------------------

    # Gem::Version or nil. Blank and unparseable both become nil: an unreadable
    # version is not evidence anybody is behind, and guessing one would turn a
    # broken read into a false abort mid-sweep.
    def version_or_nil(value)
      text = value.to_s.strip
      return nil if text.empty?

      Gem::Version.new(text)
    rescue ArgumentError
      nil
    end
  end
end
