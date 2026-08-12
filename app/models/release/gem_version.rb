# frozen_string_literal: true

require "rubygems"

class Release
  # GemVersion — THE RELEASE OWNS THE VERSION.
  #
  # A version is a property of the RELEASE, not of any PR. N pull requests riding
  # one candidate publish exactly ONE version, so no individual PR can know the
  # right answer at the moment it is written. Every version collision this pipeline
  # has suffered is that mismatch, and they are expensive: a PR carrying an
  # ALREADY-PUBLISHED version leaves origin/release ahead of the last tag without
  # advancing past it, which is the stranded-work guard's exact trigger — and that
  # guard hard-aborts the sweep for EVERY repo, not just the gem.
  #
  # MEASURED, not imagined (2026-08-10): four open studio-engine PRs each chose a
  # version independently — 0.33.0 (already published), 0.34.0, 0.35.0, against an
  # accepted at 0.33.0. The obvious remedy for the first collides with the second,
  # so the naive fix just moves the collision one PR to the right.
  #
  # So the builder never writes a version at all. This module computes it from the
  # candidate's MEMBERSHIP at prepare time — the first moment the full membership is
  # actually known — using metadata every task already carries.
  #
  # DELIBERATELY PURE: no board, no git, no network. Callers hand in the member
  # descriptors and the last published version; every rule here is unit-testable,
  # which matters more than usual because the output feeds an IRREVERSIBLE
  # `gem push`.
  module GemVersion
    # Ordered weakest → strongest so `max_by` reads as "the largest impact wins".
    BUMPS = %w[patch minor major].freeze

    # Impact by task kind, when no explicit override is given. `feature` earns a
    # minor because it adds surface consumers may start depending on; `bug` and
    # `chore` earn a patch. An unknown/blank kind degrades to `patch` — the
    # SMALLEST bump, deliberately: a wrong-but-small version is recoverable by
    # bumping again, while an unearned major is a permanent lie in the history.
    KIND_BUMPS = { "feature" => "minor", "bug" => "patch", "chore" => "patch" }.freeze
    DEFAULT_BUMP = "patch"

    # A risk tag that forces a major regardless of kind. Matched loosely (substring,
    # case-insensitive) because risk tags are free text typed by hand: `breaking`,
    # `breaking-change`, and `BREAKING API` must all count. Missing a genuine
    # breaking change is the expensive direction, so this errs toward catching it.
    BREAKING_TAG = /breaking/i

    module_function

    # The bump ONE member earns. `member` is a Hash-like with "kind", "risk_tags",
    # and optionally "gem_bump" (the operator/builder override).
    #
    # Precedence, strongest first:
    #   1. an explicit `gem_bump` override — someone said so on purpose
    #   2. a `breaking` risk tag — major, whatever the kind claims
    #   3. the kind's default
    def member_bump(member)
      override = normalize_bump(member["gem_bump"])
      return override if override

      return "major" if Array(member["risk_tags"]).any? { |tag| BREAKING_TAG.match?(tag.to_s) }

      KIND_BUMPS.fetch(member["kind"].to_s.strip.downcase, DEFAULT_BUMP)
    end

    # The bump the RELEASE earns: the largest any member earns. One patch-level
    # chore riding beside a breaking change does not dilute it.
    # Returns nil for an EMPTY membership — "no members" is not "patch"; it means
    # there is nothing to publish, and the caller must not invent a version.
    def release_bump(members)
      bumps = Array(members).map { |m| member_bump(m) }
      return nil if bumps.empty?

      bumps.max_by { |b| BUMPS.index(b) || 0 }
    end

    # The version to publish: `last_published` advanced by the members' bump.
    # nil when there is nothing to publish or the last version cannot be parsed —
    # NEVER a guess. A caller that cannot read the last published version must
    # abort, not default to 0.0.1 and push it.
    def next_version(last_published, members)
      bump = release_bump(members)
      return nil unless bump

      advance(last_published, bump)
    end

    # Pure semver arithmetic on a "X.Y.Z" string. Returns nil on anything it cannot
    # parse confidently — including pre-release/build metadata, which this pipeline
    # does not publish and which must not be silently truncated into a release.
    def advance(last_published, bump)
      raw = last_published.to_s.strip.sub(/\Av/, "")
      return nil unless /\A\d+\.\d+\.\d+\z/.match?(raw)

      major, minor, patch = raw.split(".").map(&:to_i)
      case bump
      when "major" then "#{major + 1}.0.0"
      when "minor" then "#{major}.#{minor + 1}.0"
      when "patch" then "#{major}.#{minor}.#{patch + 1}"
      end
    end

    # A caller-supplied bump, or nil when absent/unrecognized. An unrecognized value
    # is IGNORED rather than fatal so a typo degrades to the derived default instead
    # of wedging a release — but see `invalid_bump?`, which lets the CLI reject it at
    # the point a human can still fix it.
    def normalize_bump(value)
      normalized = value.to_s.strip.downcase
      BUMPS.include?(normalized) ? normalized : nil
    end

    def invalid_bump?(value)
      raw = value.to_s.strip
      !raw.empty? && normalize_bump(raw).nil?
    end

    # Why this version, in one line, for the release log and the gate note. A
    # version that appears with no explanation is one nobody can audit — and this
    # one feeds an irreversible push.
    def explain(last_published, members)
      bump = release_bump(members)
      return "no gem members — nothing to publish" unless bump

      driver = Array(members).max_by { |m| BUMPS.index(member_bump(m)) || 0 }
      "#{last_published} + #{bump} (#{member_bump(driver)} from #{driver["slug"] || driver["kind"]}) " \
        "→ #{advance(last_published, bump)}"
    end

    # --- ALLOCATION: the decision `bin/release prepare` step 4d makes -----------
    #
    # Everything above computes a version. THIS decides whether to write one at
    # all, and it is the part that had no caller: prepare read the version_file
    # and never wrote it, so the conductor hand-edited `lib/studio/version.rb`
    # before every gem release (the recipe at qa-release.md's STRANDED GEM WORK
    # row) and the stranded-work guard existed to catch the times he forgot.
    #
    # THREE ANSWERS, never two. `allocate` and `skip` are the obvious pair;
    # `refuse` is the one that matters, because the output feeds an IRREVERSIBLE
    # `gem push` and a RubyGems number can never be re-pushed. Anywhere the right
    # version is ambiguous this returns `refuse` and the caller aborts with ZERO
    # gems published — the same discipline `next_version` already keeps by
    # returning nil rather than inventing a version. A refused sweep costs a
    # re-run; a wrong allocation costs the number forever.
    #
    # STILL PURE: the caller supplies the git and network reads (the version at
    # origin/release, the last v* tag, RubyGems' live list, the commits past the
    # tag), so every branch below is unit-testable without touching either.
    ALLOCATE = "allocate"
    SKIP     = "skip"
    REFUSE   = "refuse"

    Decision = Struct.new(:action, :version, :reason, keyword_init: true) do
      def allocate?
        action == ALLOCATE
      end

      def refuse?
        action == REFUSE
      end

      def skip?
        action == SKIP
      end
    end

    # The allocation decision for ONE swept gem.
    #
    #   current       — the version declared at origin/release ("" / garbage is fine)
    #   tag_version   — the last v* tag reachable from that tip, without the "v"
    #   live_versions — what RubyGems already has (strings, or the versions-API hashes)
    #   ahead_commits — the commits between that tag and the tip
    #   members       — this gem's candidate members (kind / risk_tags / gem_bump)
    #
    # SKIP is the answer whenever allocation has no business acting, and the two
    # skips are different: nothing to publish (no commits past the tag), and
    # already allocated (`current` is strictly past everything published — an
    # idempotent re-run, or a deliberate hand-bump). The second is what keeps a
    # re-run from burning a fresh number every pass, and it is deliberately the
    # EXACT complement of the stranded-work guard's trigger: this allocates in
    # precisely the cases that guard fires on, which is why the guard stays
    # armed behind it as the backstop rather than being replaced by it.
    def allocation(current:, tag_version:, live_versions:, ahead_commits:, members:)
      members = Array(members)
      commits = Array(ahead_commits).map { |c| c.to_s.strip }.reject(&:empty?)
      live    = live_numbers(live_versions)

      return skip_decision("no commits past the last published tag — nothing to publish") if commits.empty?

      # An override nobody can read must never degrade quietly into a push. The
      # module's own `normalize_bump` ignores a typo on purpose (a wrong tag must
      # not wedge a release), but HERE is the point a human can still fix it, and
      # `invalid_bump?` exists for exactly this call.
      typos = members.select { |m| invalid_bump?(m["gem_bump"]) }
      if typos.any?
        named = typos.map { |m| "#{m["slug"] || m["kind"]}=#{m["gem_bump"]}" }.join(", ")
        return refuse_decision("unrecognized gem_bump override (#{named}) — expected #{BUMPS.join('|')}")
      end

      published = [tag_version, *live].map { |v| v.to_s.strip }.reject(&:empty?)
      # Never published by either record: this is a FIRST publish, and there is
      # no floor to derive from. Leave the declared version alone rather than
      # invent 0.0.1 and push it.
      return skip_decision("no published version yet (no v* tag, nothing on RubyGems) — first publish") if published.empty?

      # WHETHER TO ALLOCATE is judged against the TAG ALONE — deliberately the
      # same reference the stranded-work guard uses, so the two can never
      # disagree about whether this gem needs a version. A version already past
      # the last tag is settled: either it is unpublished (phase 2 publishes it)
      # or it is live (phase 2 skips it), and in BOTH cases a fresh number would
      # be unearned. Judging this against the live list instead would re-allocate
      # every time a publish landed but its tag push did not — burning a RubyGems
      # number per re-run for a version that was already released.
      # The tag when there is one; the highest live version only when there is
      # not (a repo whose tags never came down still has a reference).
      reference = tag_version.to_s.strip.empty? ? highest_version(live) : tag_version
      if newer?(current, reference)
        return skip_decision("#{current} already advanced past #{reference} — allocated already")
      end

      # WHAT TO ALLOCATE is a different question, and here the live list DOES
      # count: the floor is the highest of both records, because a tag that lags
      # a publish would otherwise hand back a number RubyGems already has and can
      # never take again.
      baseline = highest_version(published)
      # PUBLISHED, but nothing readable to bump from — a different answer from
      # the skip above, and the distinction matters: "never published" is safe to
      # walk past, "published, unreadable" is a floor we cannot see, and
      # allocating over it could re-tread a live number. Refuse and let a human
      # look at it.
      unless baseline
        return refuse_decision("cannot parse the last published version (#{published.uniq.join(', ')}) — " \
                               "fix the tag or the version_file by hand")
      end

      bump = release_bump(members)
      return refuse_decision("no gem members on this candidate — nothing to derive a bump from") unless bump

      allocated = advance(baseline, bump)
      return refuse_decision("cannot parse the last published version #{baseline.inspect} — fix it by hand") unless allocated
      # Also unreachable by construction, and kept anyway: this is the assertion
      # that the number about to be pushed is not already spent.
      return refuse_decision("#{allocated} is already live on RubyGems and can never be re-pushed") if live.include?(allocated)

      Decision.new(action: ALLOCATE, version: allocated,
                   reason: explain(baseline, members))
    end

    def skip_decision(reason)
      Decision.new(action: SKIP, version: nil, reason: reason)
    end

    def refuse_decision(reason)
      Decision.new(action: REFUSE, version: nil, reason: reason)
    end

    # The highest STRICT x.y.z among the candidates, or nil when none parses.
    # Pre-release/build metadata is dropped rather than ranked: this pipeline does
    # not publish it, and `advance` refuses it, so letting one become the baseline
    # would only turn a skip into a refusal one step later.
    def highest_version(candidates)
      Array(candidates)
        .map { |c| c.to_s.strip.sub(/\Av/, "") }
        .select { |c| /\A\d+\.\d+\.\d+\z/.match?(c) }
        .max_by { |c| Gem::Version.new(c) }
    end

    # TRUE only when `current` is a strict x.y.z STRICTLY greater than `reference`.
    # EITHER side being unreadable reads as NOT newer — which routes it to
    # allocation, matching the stranded-work guard, where an unparseable version is
    # a block and not a pass.
    def newer?(current, reference)
      raw = current.to_s.strip.sub(/\Av/, "")
      ref = reference.to_s.strip.sub(/\Av/, "")
      return false unless /\A\d+\.\d+\.\d+\z/.match?(raw) && Gem::Version.correct?(ref)

      Gem::Version.new(raw) > Gem::Version.new(ref)
    end

    # The version literal a registered `version_file` declares. ONE grammar covers
    # both registered shapes — `VERSION = "0.38.0"` (studio-engine's
    # lib/studio/version.rb) and `spec.version = "0.4.7"` (solana-studio's
    # gemspec) — and it is the same expression bin/release already reads them
    # with, so a file this can be read from is a file this can be written to.
    VERSION_LITERAL = /version\s*=\s*["']([\w.\-]+)["']/i

    # `text` with its declared version replaced by `version`, or nil when the file
    # does not declare EXACTLY ONE version.
    #
    # Zero matches and two matches are both nil on purpose. A version_file that
    # names its version twice is ambiguous about which one publishes, and this
    # write feeds an irreversible push — so the caller refuses and a human looks,
    # rather than this picking the first one and hoping. (Both registered files
    # match exactly once today; `spec.required_ruby_version = ">= 3.0"` does not
    # match, because `>` is not a version character.)
    def rewrite_version(text, version)
      body = text.to_s
      return nil unless body.scan(VERSION_LITERAL).size == 1
      return nil unless /\A\d+\.\d+\.\d+\z/.match?(version.to_s)

      body.sub(VERSION_LITERAL) { |literal| literal.sub(Regexp.last_match(1), version.to_s) }
    end

    # Accepts the versions-API shape ({"number" => "x"}) as well as bare strings,
    # so a caller that forgets to flatten the API payload gets a working
    # already-live check instead of one that silently never matches.
    def live_numbers(entries)
      Array(entries).map { |e| (e.is_a?(Hash) ? (e["number"] || e[:number]) : e).to_s.strip }.reject(&:empty?)
    end

    # HOW A GEM MEMBER'S VERSION IS NAMED in the release log — the provenance line
    # where someone later answers "what version did this task ship in?".
    #
    # THE DEFECT THIS REPLACES: prepare printed that line from the version read out
    # of the PRIMARY CHECKOUT, which sits on `main`. Since version allocation
    # landed, `main` is ONE RELEASE BEHIND BY CONSTRUCTION at that point — the
    # allocator commits the bump to origin/release and nothing fast-forwards `main`
    # until `bin/release ship`. So the line was not occasionally wrong, it was
    # GUARANTEED wrong on every gem-bearing release: rel-20260812-3f1f9b printed
    # "studio-engine 0.40.0" a few lines after printing "allocated 0.41.0" and
    # "Successfully registered gem: studio-engine (0.41.0)".
    #
    # The honest source is the PUBLISH map — what `publish_gems_for_qa` actually
    # pushed (or found already live) — keyed by repo. Everything else is a
    # fallback and SAYS SO, because a labelled guess is recoverable and an
    # unlabelled one is what caused this.
    #
    #   published: { repo => version } from publish_gems_for_qa; "" for a
    #     --dry-run entry, and the repo is absent entirely if it never reached the
    #     publish plan.
    #   local: the version read from the local checkout — a fallback ONLY, and
    #     rendered with its provenance attached.
    def reported_version(published, repo, local = "")
      map = published.is_a?(Hash) ? published : {}
      from_publish = map[repo].to_s.strip
      return from_publish unless from_publish.empty?

      # The repo IS in the map but carries no version: the --dry-run entry, where
      # nothing was allocated and nothing published. Naming any number there would
      # be inventing one.
      return "version pending (dry run)" if map.key?(repo)

      text = local.to_s.strip
      text.empty? ? "version unknown" : "#{text} (local checkout — NOT the published version)"
    end
  end
end
