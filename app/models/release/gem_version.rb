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
  end
end
