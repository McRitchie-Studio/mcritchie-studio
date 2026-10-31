# frozen_string_literal: true

# THE SHIP'S PR-READ PREFLIGHT: which release repos can the ship's GitHub identity
# NOT read pull requests in?
#
# WHAT IT FIXES (task release-gem-doc-followups). After rel-20261029-00560a deployed,
# the containment check (Release::MemberContainment, bin/release.rb
# ship_containment_holds) asked GitHub for each member's merge commit. The ship runs
# as the deployer App (github.mcritchie-admin), which holds no `pull_requests` grant;
# GitHub still serves a PUBLIC repo's PRs to any token, so the gap shows only on a
# PRIVATE repo. voicebox and alex-build are private, their PR reads failed, and four
# cards sat at `assembled` with "could not prove" notes. The git-ancestry fallback
# (MemberContainment.git_fallback_shas) now covers that read, but nothing said up
# front that the identity was blind there. This says it, before the ship moves.
#
# A WARNING, NEVER A STOP. The fallback proves containment without the PR read, so
# refusing a ship over it would trade a recoverable note for a blocked release.
# Granting the App access is Alex McRitchie's GitHub-settings click; the warning
# names exactly what to grant, and no agent attempts it.
#
# PURE: the reader is injected (-> [ok, output] for one repo), so the unit tests
# drive every outcome with no network. bin/release.rb wires the real `gh` read.
module ShipPrAccess
  module_function

  # The repos whose PR read failed, in the order given, each with the reader's own
  # words (trimmed), as [[repo, reason], ...]. A reader that RAISES counts as
  # unreadable with the error named: a preflight bug must not hide the gap it exists
  # to show.
  def unreadable(repos, reader:)
    Array(repos).map(&:to_s).reject(&:empty?).uniq.filter_map do |repo|
      ok, output = reader.call(repo)
      ok ? nil : [repo, reason(output)]
    rescue StandardError => e
      [repo, "#{e.class}: #{reason(e.message)}"]
    end
  end

  # The output's first non-blank line, capped, so one line per repo stays readable.
  def reason(output)
    line = output.to_s.lines.map(&:strip).find { |l| !l.empty? }.to_s
    line.empty? ? "no output" : line[0, 140]
  end

  # The operator-facing warning, or nil when every repo is readable. +identity+ is
  # the 1Password item the ship mints from (GH_APP_ITEM), named so the grant lands
  # on the right App.
  def warning(unreadable, identity:)
    return nil if unreadable.empty?

    names = unreadable.map(&:first)
    lines = unreadable.map { |repo, why| "      - #{repo}: #{why}" }
    <<~TXT.rstrip
      ⚠ PR READ PREFLIGHT: the ship's GitHub identity (#{identity}) cannot read pull requests in #{names.size} release repo(s): #{names.join(', ')}
      #{lines.join("\n")}
        The ship goes on: after the deploy, the containment check falls back to git ancestry for these repos
        instead of the PR read, and a member it still cannot prove stays at `assembled` with a note.
        To close the gap (Alex McRitchie's GitHub-settings click; no agent grants it): GitHub → McRitchie-Studio
        → Settings → GitHub Apps → the #{identity} App → Configure: add #{names.join(', ')} under Repository
        access, and grant Repository permissions → Pull requests: Read-only.
    TXT
  end
end
