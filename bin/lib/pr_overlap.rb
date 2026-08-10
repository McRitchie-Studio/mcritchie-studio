# frozen_string_literal: true

# PrOverlap — "which OTHER open PR touches the files I am about to hand off?"
#
# WHY IT RUNS AT SHIP AND NOT ONLY AT BEGIN. bin/session-preflight has computed this
# since the fast lane existed — but it runs inside `bin/task begin`, against a branch
# that is "ahead 0, behind 0". With no commits there are no changed files, so it
# prints "File overlap: none" and means nothing by it, and it never runs again. The
# one moment the answer is both KNOWABLE and DECISIVE — the diff is final, the
# sibling PRs are open — had no check at all.
#
# WHAT THAT COST (2026-08-10, measured not imagined). studio-engine PRs #85 and #87
# each bumped lib/studio/version.rb to the SAME 0.33.0 and each wrote its own
# CHANGELOG section. Nothing warned, because version.rb MERGES CLEANLY when both
# sides write the identical line — git's three-way sees agreement, not conflict. Had
# they shipped in separate releases, the second would have left origin/release ahead
# of tag v0.33.0 with the version not advanced past it, and the stranded-work guard
# would have hard-aborted the sweep FOR EVERY REPO. The same class collided twice
# more on config/e2e_lane.yml. These are shared-ledger files — a version, a
# changelog, a counter — that many PRs touch by nature and that no merge conflict
# will warn you about.
#
# IT WARNS, IT NEVER BLOCKS. Overlap is normal in a parallel shop and usually
# harmless; the goal is to put a fact in front of the builder at the moment a
# deliberate choice is cheap (batch these, or bump to the next version). A false
# block would wedge legitimate concurrent work, which is a worse failure than the one
# being prevented.
#
# PURE BY CONSTRUCTION: the caller supplies the file lists (it already owns an
# authenticated `gh`), so every rule here is unit-testable without a network.
module PrOverlap
  module_function

  # current_files: this branch's changed paths. prs: [{ "number", "title", "url",
  # "files" => [...] }] for OTHER open PRs. Returns [{number,title,url,files}], most
  # overlapping first, so the loudest collision is read first.
  def report(current_files, prs)
    mine = Array(current_files).map(&:to_s).reject(&:empty?).uniq
    return [] if mine.empty?

    Array(prs).filter_map { |pr|
      shared = mine & Array(pr["files"]).map(&:to_s)
      next if shared.empty?

      { "number" => pr["number"], "title" => pr["title"].to_s, "url" => pr["url"].to_s,
        "files" => shared.sort }
    }.sort_by { |item| -item["files"].size }
  end

  # The advisory block, or [] when nothing overlaps. Shaped for a builder about to
  # hand off: name the PR, name the shared paths, and say what the choice IS — the
  # warning is useless if it only says "overlap" and leaves the reader to infer why
  # they should care.
  def lines(items)
    return [] if items.empty?

    out = ["same-file overlap with #{items.size} open PR(s) — not a blocker, but decide deliberately:"]
    items.each do |item|
      out << "  PR ##{item["number"]} #{item["url"]}"
      out << "    shares: #{item["files"].join(", ")}"
      hint = ledger_hint(item["files"])
      out << "    ⚠ #{hint}" if hint
    end
    out << "  If both land in one release this is usually fine; if they ship SEPARATELY, the"
    out << "  second one must not re-claim a value the first already published."
    out
  end

  # The shared-ledger files where "merges cleanly" is precisely the danger, each with
  # the specific bad outcome rather than a generic caution. Matched on basename so a
  # gem's version.rb matches wherever it lives.
  LEDGERS = {
    "version.rb" => "a VERSION both PRs set merges clean and silently — if they ship in " \
                    "separate releases the stranded-work guard aborts the whole sweep. Batch them, or bump past.",
    "CHANGELOG.md" => "two sections for one version — reconcile to a single dated entry.",
    "e2e_lane.yml" => "a spec COUNTER — the second PR to land must re-run the lister and re-cert."
  }.freeze

  def ledger_hint(files)
    hits = Array(files).filter_map { |f| LEDGERS[File.basename(f.to_s)] }.uniq
    hits.empty? ? nil : hits.join(" ")
  end
end
