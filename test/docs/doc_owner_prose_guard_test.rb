# frozen_string_literal: true

require "test_helper"

# GUARD (reslot-souls-heartbeats, 2026-07-22): after the lane reslot, **Avi owns
# qa-release** (the accepted→release sweep + QA, the G3 assembler) and **Steffon
# owns production-deploy** (the ship, the G4 deployer). Carl owns review.
#
# The existing tripwires (sop_registry_docs_test, review_lane_docs_test, …) guard
# the SOP FILE LOCATIONS and a handful of pinned PHRASES — NOT the owner-PROSE. A
# doc can link `avi/sops/qa-release.md` while its sentence still says "Steffon's
# qa-release", and every path/phrase guard stays green. That is the exact gap this
# test closes.
#
# WIDENED 2026-07-28 (correct-devops-vocabulary-lane-owners) after this guard
# missed the worst instance in the repo. `config/devops_vocabulary.yml` — the file
# that declares itself the single source of truth that "cannot drift" — carried
# inverted lane owners for three weeks and rendered them live at /stages/sop.
# Three independent defects let it through, all three fixed below:
#
#   1. SCOPE — the glob rooted at docs/agents/, so config/ was never read at all.
#   2. LINE-SCOPED READS — File.foreach matched per line, so a `\s+` in a pattern
#      could never span a newline. That is how parallel-agent-devops.md:442-443
#      evaded the guard written for it: "Steffon's" ended one line and
#      "`qa-release`" began the next.
#   3. SPELLINGS, NOT THE PROPERTY — matching two possessive forms cannot see
#      `owner: Steffon` under `lane: Assemble`, which is how the vocabulary
#      states ownership. Prose patterns can only ever chase spellings, so the
#      structural claim now gets its own assertion against the parsed data.
#
# NOT flagged (and why the patterns are the WRONG-owner form, not the act name):
#   · the CORRECT owner phrasings — "Avi's qa-release", "Steffon's production-deploy".
#   · handoff-DIRECTION phrases — "Avi → Steffon handoff", "hands ... to Steffon",
#     "ready for Steffon's production-deploy" — they all name the CORRECT owner.
#   · historical incident wording — "qa-release ran as a Steffon subagent on
#     2026-07-11" — different phrasing, not the possessive ownership claim.
#   · frozen records under docs/agents/audits/** and any /archive path.
class DocOwnerProseGuardTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")
  CONFIG = Rails.root.join("config")

  # The post-reslot lane→owner truth. Asserted structurally below, and the
  # source of every prose pattern that follows.
  LANE_OWNERS = { "Assemble" => "Avi", "Ship" => "Steffon" }.freeze

  # WRONG-owner ownership claims. `\s+` spans newlines because the scan reads
  # whole-file text, so a phrase wrapped across a line break is still caught.
  WRONG_OWNER = [
    [/(?:Steffon(?:'s|’s))\s+`?qa-release`?/i,
     "qa-release is Avi's now (G3 — the assembler) — not Steffon's"],
    [/(?:Avi(?:'s|’s))\s+`?production-deploy`?/i,
     "production-deploy is Steffon's now (G4 — the deployer) — not Avi's"],
    [/Steffon\s*@\s*assemble/i,
     "the Assemble lane (G3) is Avi's — not Steffon's"],
    [/Avi\s*@\s*ship/i,
     "the Ship lane (G4) is Steffon's — not Avi's"],
    [/Steffon(?:'s|’s)\s+(?:self-healing\s+)?sweep/i,
     "the accepted→release sweep is Avi's — not Steffon's"],
    [/Steffon(?:'s|’s)\s+QA\s+intent/i,
     "QA intent is recorded for Avi (G3) — not Steffon"],
    [/Avi(?:'s|’s)\s+ship\s+intent/i,
     "ship intent is recorded for Steffon (G4) — not Avi"]
  ].freeze

  # Live prose that an agent may act on: the agent docs plus the config files
  # that RENDER to an operator surface. Frozen records are excluded.
  def live_sources
    (Dir.glob(AGENTS.join("**", "*.md")) + Dir.glob(CONFIG.join("**", "*.yml"))).reject do |p|
      p.include?("/audits/") || p.include?("/archive")
    end
  end

  # Whole-file scan. Returns [line_no, why, matched_text] per hit; the line number
  # is derived from the match offset so reporting stays as precise as the old
  # per-line read without inheriting its blind spot.
  def wrong_owner_hits(text)
    WRONG_OWNER.flat_map do |pattern, why|
      text.to_enum(:scan, pattern).map do
        match = Regexp.last_match
        [text[0, match.begin(0)].count("\n") + 1, why, match[0].gsub(/\s+/, " ")]
      end
    end
  end

  test "the vocabulary's lane owners match the post-reslot truth" do
    actual = Devops::Vocabulary.lanes.to_h { |lane| [lane[:lane], lane[:owner]] }

    LANE_OWNERS.each do |lane, owner|
      assert_equal owner, actual[lane],
        "config/devops_vocabulary.yml renders /stages/sop — the #{lane} lane must be " \
        "owned by #{owner} after the 2026-07-22 reslot, but it says #{actual[lane].inspect}. " \
        "This is the claim prose patterns cannot see."
    end
  end

  test "no live agent doc or rendered config names the OLD lane owner" do
    offenders = live_sources.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      wrong_owner_hits(File.read(path)).map do |line_no, why, matched|
        "#{rel}:#{line_no}  — #{why}\n      #{matched}"
      end
    end

    assert_empty offenders,
      "These LIVE sources still name the OLD owner after the 2026-07-22 reslot " \
      "(Avi owns qa-release and the Assemble lane; Steffon owns production-deploy " \
      "and the Ship lane). Flip the prose:\n#{offenders.join("\n")}"
  end
end
