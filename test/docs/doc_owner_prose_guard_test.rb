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

  # ── The ownership PROPERTY ────────────────────────────────────────────────
  #
  # WRONG_OWNER below enumerates wrong SPELLINGS, and that is structurally a
  # ratchet with no teeth: it only ever catches the phrasings already removed, so
  # a corrected string can come straight back in a shape nobody listed. Round 2
  # of this task's review fixed "Avi ship gate" in config/devops_test_suites.yml
  # and added no pattern — round 3 proved that exact string could return with the
  # guard green, alongside ten other realistic forms ("Steffon assembles",
  # "Avi ships `release → main`", "| qa-release | Steffon |", …).
  #
  # So the load-bearing check is this table: each act has ONE canonical owner, and
  # wherever prose names a soul in an ownership position next to that act, it must
  # name THAT soul. Adding an act is one row; every phrasing shape below covers it
  # automatically.
  ACT_OWNER = {
    "qa-release" => "Avi",
    "production-deploy" => "Steffon",
    "pre-QA gate" => "Avi",
    "ship gate" => "Steffon"
  }.freeze

  ACTS = Regexp.union(ACT_OWNER.keys.map { |act| /#{Regexp.escape(act)}/i })

  # The owner named just before the act, with the same capped word-bounded gap
  # that lets a qualifying clause through ("Avi's otherwise prod-stopping
  # qa-release lane") without leaping a sentence.
  OWNER_BEFORE_ACT = /\b(Avi|Steffon)(?:'s|’s)?(?:\s+[\w-]+){0,2}\s+[`*]{0,3}(#{ACTS})/i

  # A table row pairing an act with an owner: | qa-release | Steffon |
  ACT_TABLE_ROW = /\|\s*[`*]{0,3}(#{ACTS})[`*]{0,3}\s*\|\s*(Avi|Steffon)\b/i

  # The lane VERB, which names ownership without naming the act at all.
  SOUL_VERB = /\b(Avi|Steffon)\s+(ships?|assembles?)\b/i
  VERB_OWNER = { "ship" => "Steffon", "assemble" => "Avi" }.freeze

  # The PASSIVE form reverses the order — "assembled by Steffon" — so a
  # soul-before-verb shape reads straight past it.
  ACT_BY_SOUL = /\b(assembled|shipped)\s+by\s+(Avi|Steffon)\b/i
  PARTICIPLE_OWNER = { "assembled" => "Avi", "shipped" => "Steffon" }.freeze

  def canonical_act(matched)
    ACT_OWNER.keys.find { |act| act.casecmp?(matched.to_s.strip) }
  end

  # Every place the text names the WRONG soul for an act. Returns
  # [line_no, why, matched_text].
  def ownership_violations(text)
    found = []

    add = lambda do |match, soul, expected, subject|
      return if expected.nil? || soul.casecmp?(expected)
      found << [text[0, match.begin(0)].count("\n") + 1,
                "#{subject} is #{expected}'s — not #{soul}'s",
                match[0].gsub(/\s+/, " ").strip]
    end

    text.to_enum(:scan, OWNER_BEFORE_ACT).each do
      match = Regexp.last_match
      act = canonical_act(match[2])
      add.call(match, match[1], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, ACT_TABLE_ROW).each do
      match = Regexp.last_match
      act = canonical_act(match[1])
      add.call(match, match[2], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, SOUL_VERB).each do
      match = Regexp.last_match
      verb = match[2].downcase.sub(/s\z/, "")
      add.call(match, match[1], VERB_OWNER[verb], "#{verb}ing")
    end

    text.to_enum(:scan, ACT_BY_SOUL).each do
      match = Regexp.last_match
      participle = match[1].downcase
      add.call(match, match[2], PARTICIPLE_OWNER[participle], participle)
    end

    found
  end

  # An intervening clause must not hide an ownership claim. "Steffon's otherwise
  # prod-stopping `qa-release` lane" is the same assertion as "Steffon's
  # `qa-release`", and a whitespace-only gap could not see it — that phrasing sat
  # four lines below a corrected sentence in deployment.md and this guard read the
  # file as clean. GAP allows a short qualifying clause between the possessive and
  # the act name; it is word-bounded and capped so it cannot leap a sentence
  # boundary and pair two unrelated mentions.
  GAP = /(?:\s+[\w-]+){0,4}\s+/
  WRONG_OWNER = [
    [/(?:Steffon(?:'s|’s))#{GAP}`?qa-release`?/i,
     "qa-release is Avi's now (G3 — the assembler) — not Steffon's"],
    [/(?:Avi(?:'s|’s))#{GAP}`?production-deploy`?/i,
     "production-deploy is Steffon's now (G4 — the deployer) — not Avi's"],
    [/Steffon\s*@\s*assemble/i,
     "the Assemble lane (G3) is Avi's — not Steffon's"],
    [/Avi\s*@\s*ship/i,
     "the Ship lane (G4) is Steffon's — not Avi's"],
    # Scoped to the accepted→release sweep ON PURPOSE. A bare "Steffon's sweep"
    # would false-trip on `archive-shipped`, which genuinely IS Steffon's sweep —
    # a guard that cries wolf on correct prose gets muted, and then it protects
    # nothing.
    [/Steffon(?:'s|’s)\s+(?:self-healing\s+)?sweep#{GAP}(?:promotes|merges|accepted)/i,
     "the accepted→release sweep is Avi's — not Steffon's"],
    # Possessive OPTIONAL: "the Steffon QA intent" is the same ownership claim as
    # "Steffon's QA intent", and a possessive-only pattern read straight past it in
    # devops-cycle-design.md's qa-release step list.
    [/Steffon(?:'s|’s)?\s+QA\s+intent/i,
     "QA intent is recorded for Avi (G3) — not Steffon"],
    [/Avi(?:'s|’s)?\s+ship\s+intent/i,
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

  # A lane can carry the right owner in its `owner:` field and the WRONG one in its
  # prose. owner_note renders at /stages/sop twice — as the badge's title= tooltip
  # and again in the expanded Owner detail — so an inverted note is operator-facing
  # text that contradicts the badge directly above it, while every field-level
  # assertion stays green. Asserted as a PROPERTY (a lane's note must not name the
  # other lane's owner) rather than as another pattern to out-spell.
  #
  # Scoped to Assemble/Ship deliberately: those two own each other's inverse. The
  # Review lane may legitimately reference either soul when describing a handoff.
  test "no lane's owner_note names the other lane's owner" do
    notes = Devops::Vocabulary.lanes.to_h { |lane| [lane[:lane], lane[:owner_note].to_s] }

    LANE_OWNERS.each do |lane, owner|
      other = LANE_OWNERS.values.find { |candidate| candidate != owner }

      refute_includes notes.fetch(lane), other,
        "the #{lane} lane's owner_note names #{other}, but #{lane} is #{owner}'s — owner_note " \
        "renders as the badge tooltip and the expanded Owner detail, so this contradicts the " \
        "badge above it on the operator's screen"
    end
  end

  test "no live source pairs an act with the wrong owner" do
    offenders = live_sources.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      ownership_violations(File.read(path)).map do |line_no, why, matched|
        "#{rel}:#{line_no}  — #{why}\n      #{matched}"
      end
    end

    assert_empty offenders,
      "These LIVE sources pair an act with the WRONG soul. Canonical ownership after the " \
      "2026-07-22 reslot: qa-release and the pre-QA gate are Avi's (G3, the assembler); " \
      "production-deploy and the ship gate are Steffon's (G4, the deployer).\n" \
      "#{offenders.join("\n")}"
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
