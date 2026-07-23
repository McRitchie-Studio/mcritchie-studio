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
# test closes: no LIVE doc may attribute `qa-release` to Steffon or
# `production-deploy` to Avi.
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

  # The two WRONG-owner OWNERSHIP claims post-reslot. The possessive ("Steffon's"
  # / "Avi's") immediately before the act name is the ownership form; the act name
  # alone ("qa-release was run as a Steffon session") is not, and stays allowed.
  WRONG_OWNER = [
    [/(?:Steffon(?:'s|’s))\s+`?qa-release`?/i,
     "qa-release is Avi's now (G3 — the assembler) — not Steffon's"],
    [/(?:Avi(?:'s|’s))\s+`?production-deploy`?/i,
     "production-deploy is Steffon's now (G4 — the deployer) — not Avi's"]
  ].freeze

  def live_docs
    Dir.glob(AGENTS.join("**", "*.md")).reject do |p|
      p.include?("/audits/") || p.include?("/archive")
    end
  end

  test "no live agent doc attributes qa-release to Steffon or production-deploy to Avi" do
    offenders = []
    live_docs.each do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      File.foreach(path).with_index(1) do |line, lineno|
        WRONG_OWNER.each do |pattern, why|
          offenders << "#{rel}:#{lineno}  — #{why}\n      #{line.strip}" if line.match?(pattern)
        end
      end
    end

    assert_empty offenders,
      "These LIVE docs still name the OLD owner after the 2026-07-22 reslot " \
      "(Avi owns qa-release; Steffon owns production-deploy). Flip the prose:\n" \
      "#{offenders.join("\n")}"
  end
end
