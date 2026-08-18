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
#   · historical incident wording where the SOUL is not paired with an act, verb or
#     stage — "ran as a Steffon subagent on 2026-07-11". NOTE: past-tense OWNERSHIP
#     ("Steffon assembled the RC") IS flagged, deliberately — tense does not make a
#     wrong-owner claim historical.
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
  # An act ABSENT from this table is invisible to the whole mechanism, which is the
  # quiet failure mode: the guard reports clean because it was never asked about
  # `qa-deploy`. The registry in AGENTS.md is the source — every invocable act with
  # a settled owner belongs here.
  ACT_OWNER = {
    "qa-release" => "Avi",
    "qa-deploy" => "Avi",           # legacy alias — the spelling bin/release.rb and bin/conductor actually use
    "deploy-with-task" => "Avi",
    "pre-QA gate" => "Avi",
    "production-deploy" => "Steffon",
    "archive-shipped" => "Steffon",
    "ship gate" => "Steffon",
    "pr-review" => "Carl"           # Carl reowned review at the 2026-07-22 reslot
  }.freeze

  # Carl joins the alternation because `pr-review` is his. A guard that only knows
  # two souls cannot police a three-soul pipeline.
  SOULS = /(Avi|Steffon|Carl)/

  ACTS = Regexp.union(ACT_OWNER.keys.map { |act| /#{Regexp.escape(act)}/i })

  # The owner named just before the act, with the same capped word-bounded gap
  # that lets a qualifying clause through ("Avi's otherwise prod-stopping
  # qa-release lane") without leaping a sentence.
  OWNER_BEFORE_ACT = /\b#{SOULS}(?:'s|’s)?(?:\s+[\w-]+){0,2}\s+[`*]{0,3}(#{ACTS})/i

  # The owner named AFTER the act — "the qa-release sweep is Steffon's",
  # "The ship gate is Avi's". Ownership reads in both directions; a
  # before-only shape sees half of it.
  ACT_THEN_OWNER = /(#{ACTS})[`*]{0,3}(?:\s+[\w-]+){0,3}\s+(?:is|are|was|belongs\s+to|owned\s+by)\s+#{SOULS}(?:'s|’s)?/i

  # Label forms: "qa-release (Steffon)" and "qa-release: Steffon".
  ACT_LABELLED = /(#{ACTS})[`*]{0,3}\s*[(:]\s*#{SOULS}\b/i

  # A table row pairing act and owner, in EITHER column order.
  ACT_TABLE_ROW = /\|\s*[`*]{0,3}(#{ACTS})[`*]{0,3}\s*\|\s*#{SOULS}\b/i
  TABLE_ROW_REVERSED = /\|\s*#{SOULS}\s*\|\s*[`*]{0,3}(#{ACTS})/i

  # The lane VERB, which names ownership without naming the act at all. Tense and
  # modality carry the same claim, so present/past/progressive and a leading modal
  # all count — "Avi will ship" asserts ownership exactly as "Avi ships" does.
  # The optional group covers modals AND copulas — "Steffon is assembling" makes the
  # same ownership claim as "Steffon assembles", and a modal-only list read past it.
  # NEGATION included on purpose. Leaving it out produced a perverse asymmetry: a
  # review found "Avi ships nothing to production" flagged while "Avi never ships"
  # evaded — so the guard policed a sentence that merely READS wrong and ignored one
  # asserting the same wrong ownership more plainly. Both name the wrong soul for
  # the act; neither belongs in a live doc.
  SOUL_VERB = /\b#{SOULS}\s+(?:(?:will|can|cannot|never|not|should|must|then|is|was|are|has|have|does|do)\s+)*(ships?|shipped|shipping|assembles?|assembled|assembling)\b/i
  # Keyed by SURFACE FORM, not by stem. Stemming looked tidier and silently lost
  # the past tense: "assembled".sub(/s\z/, "") is "assembled", which is not a key,
  # so the lookup returned nil and the check skipped itself — a guard hole that
  # only a mutation exposed ("Steffon assembled the release" survived).
  VERB_OWNER = {
    "ship" => "Steffon", "ships" => "Steffon", "shipped" => "Steffon", "shipping" => "Steffon",
    "assemble" => "Avi", "assembles" => "Avi", "assembled" => "Avi", "assembling" => "Avi"
  }.freeze

  # The NOMINALISED form — "Avi is the shipper".
  SOUL_IS_ROLE = /\b#{SOULS}\s+is\s+the\s+(shipper|assembler|deployer|reviewer)\b/i
  ROLE_OWNER = { "shipper" => "Steffon", "deployer" => "Steffon",
                 "assembler" => "Avi", "reviewer" => "Carl" }.freeze

  # ── The STAGE anchor family ───────────────────────────────────────────────
  #
  # Every shape above anchors on an ACT NAME (`qa-release`) or a LANE VERB
  # ("ships"). A review of this guard found that ALL of the live wrong-owner
  # residue in app/ bin/ lib/ anchors on neither: it pairs a soul with a STAGE
  # NOUN — "Steffon→assembled", "shows Steffon", "Avi · ship", "waiting on
  # Steffon". Fifteen of fifteen residual sites were missed, which is what a
  # missing anchor family looks like from the inside: the guard is green and
  # confident and blind.
  #
  # Keyed off the SAME map the application resolves owners with
  # (`StageAgentsHelper::STAGE_OWNER`), read at runtime rather than restated, so
  # this family cannot drift from the behaviour it polices. `stage_agents_helper.rb:718`
  # is why that matters: it stated the inverse of `STAGE_OWNER` defined at :19 of
  # its own file, in the docstring of the function that reads it.
  STAGE_OWNER_CANON = StageAgentsHelper::STAGE_OWNER
    .transform_values { |slug| slug.to_s.capitalize }.freeze

  # PROXIMITY IS NOT AN ASSERTION. A first attempt paired any soul with any stage
  # noun inside an 18-char window, treating plain whitespace as a connector. Every
  # sampled hit was a FALSE POSITIVE — "Avi … QAs the assembled RC …; Steffon"
  # states both owners correctly, with a semicolon between them. A guard that
  # flags correct prose gets muted, and then it protects nothing.
  #
  # So this family matches only connectors that genuinely ASSERT a mapping:
  # an arrow (`Steffon→assembled`), a bullet/pipe in an owner list (`Avi · ship`),
  # or the positional "at" (`Steffon at QA`). Those are the forms the live residue
  # actually uses; ordinary prose that happens to mention both does not match.
  STAGES = Regexp.union(STAGE_OWNER_CANON.keys.map { |s| /#{Regexp.escape(s)}/i })
  ARROW = %r{\s*(?:→|->|=>)\s*}
  LISTED = %r{\s*[·|]\s*}

  SOUL_MAPS_STAGE = /\b#{SOULS}(?:#{ARROW}|#{LISTED}|\s+at\s+)\b(#{STAGES})\b/i
  STAGE_MAPS_SOUL = /\b(#{STAGES})\b(?:#{ARROW}|#{LISTED})#{SOULS}\b/i

  # The stage family reads PROSE ONLY. A markdown table row uses `·` and `|` as
  # value separators, so a long matrix row ("assembled+release = QA-green awaiting
  # Steffon") tripped it while being entirely correct — assembled+release DOES await
  # the ship, which is Steffon's. Genuine owner tables are already covered by
  # ACT_TABLE_ROW / TABLE_ROW_REVERSED, so blanking table rows here costs no
  # coverage. Line COUNT is preserved so reported line numbers stay accurate.
  def prose_only(text)
    text.lines.map { |line| line.lstrip.start_with?("|") ? "\n" : line }.join
  end

  # The PASSIVE form reverses the order — "assembled by Steffon" — so a
  # soul-before-verb shape reads straight past it.
  ACT_BY_SOUL = /\b(assembled|shipped|reviewed)\s+by\s+#{SOULS}\b/i
  PARTICIPLE_OWNER = { "assembled" => "Avi", "shipped" => "Steffon", "reviewed" => "Carl" }.freeze

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

    text.to_enum(:scan, ACT_THEN_OWNER).each do
      match = Regexp.last_match
      act = canonical_act(match[1])
      add.call(match, match[2], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, ACT_LABELLED).each do
      match = Regexp.last_match
      act = canonical_act(match[1])
      add.call(match, match[2], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, ACT_TABLE_ROW).each do
      match = Regexp.last_match
      act = canonical_act(match[1])
      add.call(match, match[2], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, TABLE_ROW_REVERSED).each do
      match = Regexp.last_match
      act = canonical_act(match[2])
      add.call(match, match[1], ACT_OWNER[act], act)
    end

    text.to_enum(:scan, SOUL_IS_ROLE).each do
      match = Regexp.last_match
      role = match[2].downcase
      add.call(match, match[1], ROLE_OWNER[role], role)
    end

    prose = prose_only(text)

    prose.to_enum(:scan, SOUL_MAPS_STAGE).each do
      match = Regexp.last_match
      stage = match[2].downcase
      add.call(match, match[1], STAGE_OWNER_CANON[stage], "the #{stage} stage")
    end

    prose.to_enum(:scan, STAGE_MAPS_SOUL).each do
      match = Regexp.last_match
      stage = match[1].downcase
      add.call(match, match[2], STAGE_OWNER_CANON[stage], "the #{stage} stage")
    end

    text.to_enum(:scan, SOUL_VERB).each do
      match = Regexp.last_match
      verb = match[2].downcase
      add.call(match, match[1], VERB_OWNER[verb], verb)
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

  # Live prose an agent may act on. WIDENED to the code trees (repo-wide-owner-sweep):
  # the guard previously read only docs + config, and its OWN checker found ten
  # genuine wrong-owner sites in app/ bin/ lib/ that it could detect but never
  # opened — while reporting clean across its in-scope files. A guard that
  # certifies inside a boundary it drew itself manufactures confidence.
  #
  # Code comments count. `bin/release.rb` prints owner strings to the operator's
  # terminal during a real ship, and an inverted comment beside a correct constant
  # (`stage_agents_helper.rb:19` vs its own docstring) hands the next reader a coin
  # flip.
  #
  # `test/` stays OUT, deliberately: a test that verifies this
  # guard has to CONTAIN offending text, so including test/ would make the guard
  # trip on its own fixtures. That is a carve-out, not an oversight — the cost is
  # that inverted comments in test/ are unguarded (known: review_lane_docs_test.rb,
  # release_cli_test.rb), which is the right trade for a guard that can never
  # cry wolf on itself.
  CODE_TREES = %w[app bin lib].map { |dir| Rails.root.join(dir) }.freeze
  CODE_GLOBS = %w[*.rb *.erb *.yml].freeze

  def guarded_sources
    docs = Dir.glob(AGENTS.join("**", "*.md")) + Dir.glob(CONFIG.join("**", "*.yml"))
    code = CODE_TREES.flat_map do |tree|
      CODE_GLOBS.flat_map { |ext| Dir.glob(tree.join("**", ext)) } +
        Dir.glob(tree.join("*")).select { |p| File.file?(p) && File.extname(p).empty? }
    end

    (docs + code).uniq.reject do |path|
      path.include?("/audits/") || path.include?("/archive") || path.include?("/node_modules/")
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
  # The pulse is each lane's FIRST rendered node and its label names the owner
  # outright ("Avi on it"). Swapping the two labels while leaving `owner:` correct
  # left the entire suite green — the same class as the owner_note hole below, on a
  # different field.
  test "no lane's pulse label names the other lane's owner" do
    LANE_OWNERS.each do |lane_name, owner|
      lane = Devops::Vocabulary.lanes.find { |candidate| candidate[:lane] == lane_name }
      pulse = lane[:steps].find { |step| step[:type] == :pulse }
      other = LANE_OWNERS.values.find { |candidate| candidate != owner }

      assert_not_nil pulse, "the #{lane_name} lane must carry a pulse step (its live-intent marker)"
      assert_includes pulse[:label].to_s, owner,
        "the #{lane_name} lane's pulse label must name #{owner} — it renders as the lane's first node"
      refute_includes pulse[:label].to_s, other,
        "the #{lane_name} lane's pulse label names #{other}, contradicting its own owner: field"
    end
  end

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

  test "no guarded agent doc or rendered config pairs an act with the wrong owner" do
    offenders = guarded_sources.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      ownership_violations(File.read(path)).map do |line_no, why, matched|
        "#{rel}:#{line_no}  — #{why}\n      #{matched}"
      end
    end

    assert_empty offenders,
      "These guarded sources pair an act with the WRONG soul. Canonical ownership after the " \
      "2026-07-22 reslot: qa-release and the pre-QA gate are Avi's (G3, the assembler); " \
      "production-deploy and the ship gate are Steffon's (G4, the deployer).\n" \
      "#{offenders.join("\n")}"
  end

  test "no live agent doc or rendered config names the OLD lane owner" do
    offenders = guarded_sources.flat_map do |path|
      rel = Pathname.new(path).relative_path_from(Rails.root).to_s
      wrong_owner_hits(File.read(path)).map do |line_no, why, matched|
        "#{rel}:#{line_no}  — #{why}\n      #{matched}"
      end
    end

    assert_empty offenders,
      "These guarded sources still name the OLD owner after the 2026-07-22 reslot " \
      "(Avi owns qa-release and the Assemble lane; Steffon owns production-deploy " \
      "and the Ship lane). Flip the prose:\n#{offenders.join("\n")}"
  end
end
