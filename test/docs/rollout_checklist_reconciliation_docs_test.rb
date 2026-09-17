# frozen_string_literal: true

require "test_helper"

# GUARD (rollout-checklist-asserts-undone-work, 2026-09-16): the turf-vault mainnet
# rollout checklist and the Squads migration record's "How it resolved" section may
# not state a status without a dated mark, a threshold without its multisig, or a
# chain slot without its program.
#
# WHAT HAPPENED. `docs/agents/system/turf-vault-mainnet-rollout.md` carried an
# UNCHECKED "Squads multisig upgrade authority transferred and rehearsed" three
# months after a `SetAuthority` transaction had done exactly that (2026-06-02). Every
# other box was the same age, and the reconciliation found it stale in BOTH
# directions: one more box was done, and several read as merely "not yet" when a
# measurement showed them false (a nightly suite that has never passed, a reconciler
# cron removed by design). An unmarked checkbox cannot say which of those it is.
# The same day, review of the migration record found a devnet slot cited in a
# sentence that named no program, which put the wrong program's deploy under the
# right program's header.
#
# THE UNDERLYING DEFECT is conflation, and it has three shapes this file pins:
#
#   1. STATUS WITHOUT A READING. A box is checked or unchecked with nothing saying
#      when, or on what evidence. Every box must carry exactly one dated mark —
#      DONE, NOT MET or UNSETTLED — and `[x]` must agree with it. UNSETTLED is a
#      first-class answer: "no read available could decide it" is a finding, and
#      the acceptance criterion asks for it by name.
#   2. A THRESHOLD WITHOUT ITS MULTISIG. Three authorities share the word
#      "multisig" here: the Squads multisig holding the upgrade authority (3-of-5
#      on both live Squads since 2026-09-15), `VaultState`'s own signer set (2-of-3
#      on the deployed v0.25), and a first mainnet Squad that still reads 2-of-3.
#      About 180 "2-of-3" mentions across these repos are CORRECT because they
#      describe `VaultState`. A bare N-of-M cannot be checked, and "correcting" a
#      right one is the likeliest regression, so every N-of-M must name
#      `VaultState` or Squads in its own paragraph, list item or table row.
#   3. A SLOT WITHOUT ITS PROGRAM. A slot number is only evidence for the program
#      it belongs to, and two devnet programs share one upgrade authority. So every
#      sentence citing a slot must name a program ID.
#
# WHAT THIS DOES NOT DO. It does not read the chain — a unit test that needed an RPC
# would be flaky, and a mark is a dated READING, not a live fact. The marks record
# what was measured; this guard makes sure a mark exists and is internally
# consistent. Re-deriving the readings is still the reader's job, and both docs say
# so. Only the "How it resolved" section of the migration record is held to rules 2
# and 3: the rest of that file is a frozen 2026-05-23 record, banner-marked as such.
class RolloutChecklistReconciliationDocsTest < ActiveSupport::TestCase
  ROLLOUT = "docs/agents/system/turf-vault-mainnet-rollout.md"
  MIGRATION = "docs/agents/system/squads-upgrade-authority-migration.md"

  MARK = /\*\*(DONE|NOT MET|UNSETTLED)\b[^*]*?\((\d{4}-\d{2}-\d{2})\)\.?\*\*/
  N_OF_M = /\b\d+(?:-of-|\s+of\s+)\d+\b/
  AUTHORITY = /VaultState|\bSquads?\b/
  SLOT = /\bslot\s+`?\d{6,}`?/
  # Program ID prefixes, as the docs truncate them. A new program joins this list
  # when it is deployed; a slot for an unlisted program fails loudly, which is the
  # point — it is a program this guard has never seen named.
  PROGRAMS = /DaFv83|EQGFJ|Dx8u|mnzow|7Hy8/
  # Evidence a DONE mark must carry after itself: a timestamp, a slot, or a
  # backticked value, command or path someone can re-read.
  EVIDENCE = /\d{4}-\d{2}-\d{2}T\d|#{SLOT.source}|`[^`]+`/

  def read(path)
    File.read(Rails.root.join(path))
  end

  # A checkbox is a line that STARTS with a box: any bullet (`-`, `*`, `+`) or
  # ordered marker (`1.`, `1)`), at any indent, holding a space, `x` or `X`, and
  # followed by whitespace or the end of the file. Blockquote markers are stripped
  # first (QUOTE), so `> - [ ]` and `> > * [ ]` are boxes too.
  #
  # That is not every box GitHub renders. A box that opens a container NESTED in a
  # list item — `- - [ ]`, `- > - [ ]`, or a `> - [ ]` indented four or more spaces
  # under its parent item — renders as a checkbox and is invisible here. The guarded
  # doc had none on 2026-09-16; teach the pattern that spelling before using it.
  #
  # WIDENED 2026-09-16 (rollout-guard-misses-checkbox-forms). The first version
  # knew one spelling, `- [ ]` / `- [x]`. An unmarked `* [ ]`, `- [X]` or `> - [ ]`
  # was therefore not a box at all to this file, so it passed — green because the
  # guard could not see the box, not because the box was marked.
  #
  # The trailing lookahead is what keeps a link out: `- [x](./file.md)` is a list
  # item whose text starts with a link, not a box. A box-shaped line inside a
  # fenced code block still counts, as it did before; that fails LOUDLY, and
  # teaching this file about fences would let one unclosed fence hide every box
  # below it.
  CHECKBOX = /\A(\s*)(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\](?=\s|\z)/
  QUOTE = /\A(?: {0,3}> ?)+/

  # A checkbox item is its box line plus every following line indented deeper
  # (after blockquote markers are stripped), so a mark or evidence on a
  # continuation line counts.
  def checkbox_items(text)
    items = []
    open_item = nil
    text.each_line.with_index(1) do |raw, number|
      line = raw.sub(QUOTE, "")
      if (m = line.match(CHECKBOX))
        open_item = { line: number, indent: m[1].size, checked: m[2].casecmp?("x"), body: +line }
        items << open_item
      elsif open_item && !line.strip.empty? && line[/\A\s*/].size > open_item[:indent]
        open_item[:body] << line
      else
        open_item = nil
      end
    end
    items
  end

  def checklist_defects(text)
    checkbox_items(text).filter_map do |item|
      marks = item[:body].scan(MARK)
      title = item[:body].lines.first.strip[0, 90]
      if marks.empty?
        "line #{item[:line]}: no dated DONE / NOT MET / UNSETTLED mark — #{title}"
      elsif marks.size > 1
        "line #{item[:line]}: #{marks.size} marks on one box — #{title}"
      elsif item[:checked] != (marks.first.first == "DONE")
        box = item[:checked] ? "[x]" : "[ ]"
        "line #{item[:line]}: box #{box} disagrees with its #{marks.first.first} mark — #{title}"
      elsif marks.first.first == "DONE" && !item[:body].split(MARK, 2).last.to_s.match?(EVIDENCE)
        "line #{item[:line]}: DONE with no evidence after the mark — #{title}"
      end
    end
  end

  # Paragraphs, list items and table rows, with blockquote markers stripped. A
  # threshold must name its authority inside one of these, not somewhere in the file.
  def blocks(text)
    out = []
    text.each_line.with_index(1) do |raw, number|
      line = raw.sub(/\A>\s?/, "")
      starts = line.strip.empty? || line.match?(/\A\s*(?:[-*]|\d+\.)\s|\A\s*\||\A#/)
      out << { line: number, text: +"" } if starts || out.empty?
      out.last[:text] << line unless line.strip.empty?
    end
    out.reject { |b| b[:text].strip.empty? }
  end

  def authority_defects(text)
    blocks(text).filter_map do |block|
      next unless block[:text].match?(N_OF_M)
      next if block[:text].match?(AUTHORITY)

      "line #{block[:line]}: #{block[:text][N_OF_M]} names no multisig — " \
        "#{block[:text].gsub(/\s+/, ' ').strip[0, 110]}"
    end
  end

  def slot_defects(text)
    flat = blocks(text).map { |b| b[:text].gsub(/\s+/, " ") }.join("\n")
    flat.split(/(?<=[.!?])\s+|\n/).filter_map do |sentence|
      next unless sentence.match?(SLOT)
      next if sentence.match?(PROGRAMS)

      "#{sentence[SLOT]} is cited in a sentence naming no program — #{sentence.strip[0, 120]}"
    end
  end

  def resolved_section(text)
    text[/^## How it resolved\n.*?(?=^## )/m] or flunk("#{MIGRATION} lost its ## How it resolved section")
  end

  # ── The live tree ─────────────────────────────────────────────────────────
  def test_every_rollout_checkbox_carries_one_dated_mark_that_agrees_with_it
    text = read(ROLLOUT)
    # A floor, so deleting the checklist cannot pass this vacuously. The
    # reconciliation marked 22 boxes; a legitimate trim may lower the floor.
    assert_operator checkbox_items(text).size, :>=, 20, "#{ROLLOUT} has lost its checklist"

    defects = checklist_defects(text)
    assert_empty defects, <<~MSG
      #{ROLLOUT} has a checkbox whose status is not a dated reading. Mark every box
      **DONE (YYYY-MM-DD).**, **NOT MET (YYYY-MM-DD).** or **UNSETTLED (YYYY-MM-DD).**,
      check it only when DONE, and follow a DONE with the evidence (a timestamp,
      slot or backticked value). UNSETTLED is a valid answer; a bare box is not.

      #{defects.join("\n")}
    MSG
  end

  def test_every_threshold_names_its_multisig
    defects = authority_defects(read(ROLLOUT)).map { |d| "#{ROLLOUT} #{d}" } +
              authority_defects(resolved_section(read(MIGRATION))).map { |d| "#{MIGRATION} (How it resolved) #{d}" }
    assert_empty defects, <<~MSG
      A threshold is stated without naming which multisig it describes. Say
      `VaultState` (the program's own signer set, 2-of-3 on the deployed v0.25) or
      Squads (the upgrade authority; name WHICH Squad when it is not a live one) in
      the same paragraph, list item or table row. Do not "fix" the number until you
      know which one it is.

      #{defects.join("\n")}
    MSG
  end

  def test_every_cited_slot_names_its_program
    defects = slot_defects(read(ROLLOUT)) + slot_defects(resolved_section(read(MIGRATION)))
    assert_empty defects, <<~MSG
      A chain slot is cited in a sentence that names no program ID. A slot is
      evidence only for its own program, and devnet runs two programs under one
      upgrade authority. Name the program (`EQGFJAcA…`, `DaFv83yo…`, …) in the
      sentence that carries the slot.

      #{defects.join("\n")}
    MSG
  end

  # ── The checker itself bites ──────────────────────────────────────────────
  #
  # The first two fixtures are VERBATIM from the tree before this task — the
  # unticked box, and the migration record's devnet sentence — so the guard is
  # pinned against the real defects, not phrasings invented to match a regex.
  def test_the_checker_catches_the_original_defects
    before = "- [ ] Squads multisig upgrade authority transferred and rehearsed " \
             "(see [`squads-upgrade-authority-migration.md`](./squads-upgrade-authority-migration.md))\n"
    assert_match(/no dated/, checklist_defects(before).join, "the original bare box read as clean")

    devnet = "> - **Mainnet program `DaFv83yo…` already holds its upgrade authority on the\n" \
             ">   Squads vault `Bk9sS7ii…`** — Step 4's whole objective. Mainnet's last deploy landed at\n" \
             ">   2026-06-11T15:15:51Z (slot `425788802`), which bounds the migration: the\n" \
             ">   authority was already on the vault by then. Devnet's last deploy was nine\n" \
             ">   minutes earlier (slot `468716417`, 2026-06-11T15:06:34Z), on the Squads\n" \
             ">   vault `BW13kgfi…`.\n"
    assert_equal 2, slot_defects(devnet).size,
                 "the original bullet cites two slots in sentences naming no program; both must be caught"
  end

  def test_the_checker_catches_each_inconsistent_mark
    {
      "checked but NOT MET" => "- [x] Item — **NOT MET (2026-09-16).** measured false\n",
      "open but DONE" => "- [ ] Item — **DONE (2026-09-16).** `evidence`\n",
      "undated mark" => "- [ ] Item — **UNSETTLED.** no read\n",
      "two marks" => "- [ ] Item — **UNSETTLED (2026-09-16).**\n  later **NOT MET (2026-09-17).**\n",
      "DONE with no evidence" => "- [x] Item `NAME` in the title — **DONE (2026-09-16).** trust me\n"
    }.each do |label, prose|
      assert_not_empty checklist_defects(prose), "#{label}: read as clean"
    end
  end

  # A box this file cannot SEE is a box it cannot hold to a mark, so an unmarked one
  # passes by being invisible. The first three spellings are the ones review proved
  # slipped past the original pattern; every one is planted bare.
  def test_the_checker_sees_every_checkbox_spelling
    {
      "star bullet" => "* [ ] Item\n",
      "capital X" => "- [X] Item\n",
      "blockquoted" => "> - [ ] Item\n",
      "plus bullet" => "+ [ ] Item\n",
      "ordered with a dot" => "1. [ ] Item\n",
      "ordered with a paren" => "2) [x] Item\n",
      "nested blockquote" => "> > * [ ] Item\n",
      "indented" => "   - [ ] Item\n",
      "empty box at end of file" => "- [ ]"
    }.each do |label, prose|
      assert_match(/no dated/, checklist_defects(prose).join, "#{label}: an unmarked box read as clean")
    end

    assert_match(/box \[x\] disagrees/, checklist_defects("- [X] Item — **NOT MET (2026-09-16).**\n").join,
                 "a capital X was seen but not read as checked")
  end

  # The widening must not reach lines that are not boxes. A guard that flags prose
  # gets muted, and then it protects nothing.
  def test_the_checker_ignores_lines_that_are_not_checkboxes
    {
      "list item that starts with a link" => "- [x](./file.md) is linked\n",
      "link whose text is X" => "* [X](https://example.com)\n",
      "no space after the bullet" => "-[ ] not a list item\n",
      "no bullet" => "[ ] bare brackets\n",
      "two characters in the box" => "- [xx] not a box\n",
      "empty brackets" => "- [] not a box\n",
      "box mid-line" => "Write `- [ ]` for an open item.\n",
      "table cell" => "| [ ] | open |\n",
      "bold brackets" => "- **[ ]** emphasis, not a box\n",
      "quoted box mid-line" => "> the old form was - [ ] only\n"
    }.each do |label, prose|
      assert_empty checkbox_items(prose), "#{label}: read as a checkbox"
    end
  end

  def test_the_checker_catches_a_bare_threshold
    assert_not_empty authority_defects("- Add admin override for emergencies (signed by 2-of-3 multisig)\n"),
                     "the original Phase B line names no multisig and read as clean"
    assert_not_empty authority_defects("| Compromise | Immediate `update_signers` via 2-of-3 cosign. |\n"),
                     "a bare threshold in a table row read as clean"
  end

  # Correct prose must pass, or the guard gets muted and protects nothing.
  def test_the_checker_passes_correct_prose
    good_box = "- [x] Transferred — **DONE (2026-09-16).**\n" \
               "  `SetAuthority` on `DaFv83yo…` at 2026-06-02T19:14:10Z (slot `423870782`).\n"
    assert_empty checklist_defects(good_box)
    assert_empty checklist_defects("- [ ] Bounty — **UNSETTLED (2026-09-16).**\n  No read decides it.\n")
    # Each of these is asserted SEEN before it is asserted clean: an empty defect
    # list from a box the checker never found would pass here for the wrong reason.
    quoted = "> - [ ] Bounty\n>   **UNSETTLED (2026-09-16).** No read decides it.\n"
    assert_equal 1, checkbox_items(quoted).size
    assert_empty checklist_defects(quoted), "a mark on a blockquoted continuation line was not attached to its box"
    starred = "* [X] Transferred — **DONE (2026-09-16).** at 2026-06-02T19:14:10Z\n"
    assert_equal 1, checkbox_items(starred).size
    assert_empty checklist_defects(starred)
    assert_empty authority_defects("> `VaultState` is the program's own signer set, still\n> 2-of-3 on the deployed v0.25.\n")
    assert_empty authority_defects("- both live Squads read 3-of-5 since 2026-09-15\n")
    assert_empty slot_defects("The live devnet program is `EQGFJAcA…`, last deployed (slot `468716417`).\n")
  end
end
