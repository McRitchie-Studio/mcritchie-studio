# frozen_string_literal: true

require "test_helper"

# GUARD (fix-stale-log-cap-docs, 2026-09-22): `kickoff-log-rotation.md` is a
# DESIGN RECORD for work that shipped, and it spent weeks teaching the broken
# version of that work.
#
# WHAT WENT WRONG. The brief proposed capping logs by assigning
# `app.config.logger` from a bare `initializer "studio.logger" do |app|`. That is
# a SILENT NO-OP — Rails' `:initialize_logger` is a *bootstrap* initializer, so it
# runs before every engine initializer and the logger already exists by then.
# studio-engine shipped something structurally different (`before:
# :initialize_logger`, setting `config.log_file_size`) and its CHANGELOG 0.33.0
# names the proposed shape as the no-op. The doc was never corrected, so a reader
# copying it would build the broken version — from a file that reads like a
# specification.
#
# WHY A DOC TEST AND NOT A GREP DURING REVIEW. Nothing executes prose. Every
# behavioural test in both repos stayed green over that sentence for its whole
# life, because the sentence is not code. The only thing that catches a doc
# asserting a mechanism the code does not have is a test that reads both.
#
# WHAT IS DERIVED, NOT TYPED. The cap floor is read out of
# `bin/lib/artifact_sweep.rb` — the hub's own audit constant, the number the
# archive sweep tells loose apps they need. The day that constant moves, this
# guard moves with it. A floor typed into a test is the same hand-maintained
# number that rotted in the first place.
#
# Every scan asserts a FLOOR before it grades, so a selector that stops matching
# fails loudly instead of passing over an empty set.
class KickoffLogRotationDocsTest < ActiveSupport::TestCase
  KICKOFF        = "docs/agents/maintenance/kickoff-log-rotation.md"
  ARCHIVE_SOP    = "docs/agents/agents/steffon/sops/archive-shipped.md"
  ARTIFACT_SWEEP = "bin/lib/artifact_sweep.rb"

  def read(relative_path)
    path = Rails.root.join(relative_path)
    assert path.exist?, "#{relative_path} is missing — this guard grades it"
    path.read
  end

  def kickoff = @kickoff ||= read(KICKOFF)

  # Collapse hard wrapping: every claim below wraps across lines.
  def collapsed(text) = text.gsub(/\s+/, " ")

  # ONLY the fenced ```ruby blocks — what a reader COPIES. The prose deliberately
  # QUOTES the broken shape in order to warn about it, and scanning the whole file
  # would report that warning as the defect it exists to prevent. Prescription and
  # discussion are different acts; only the first one builds anything.
  def prescribed_ruby
    blocks = kickoff.scan(/^```ruby\n(.*?)^```/m).flatten
    assert_operator blocks.length, :>=, 1,
                    "#{KICKOFF} has no ```ruby block. This guard grades the code a reader would copy, so an " \
                    "empty set means the selector broke, not that the doc is safe."
    collapsed(blocks.join("\n"))
  end

  # ── THE CODE THIS GRADES AGAINST ────────────────────────────────────────────

  def derived_cap_floor
    floor = read(ARTIFACT_SWEEP)[/^\s*ENGINE_CAP_FLOOR\s*=\s*["']([\d.]+)["']/, 1]
    assert floor,
           "#{ARTIFACT_SWEEP} lost ENGINE_CAP_FLOOR — the constant this guard derives the documented " \
           "log-cap floor from. Losing it means the floor is underived, not that there is no floor."
    floor
  end

  # ── THE NO-OP RECIPE MUST NOT COME BACK ─────────────────────────────────────

  test "[static] the kickoff never teaches assigning app.config.logger from an initializer" do
    body = prescribed_ruby

    refute_match(/initializer\s+"studio\.logger"\s+do\s+\|app\|/, body,
                 "#{KICKOFF} declares `initializer \"studio.logger\" do |app|` with NO ordering. Rails' " \
                 ":initialize_logger is a bootstrap initializer and has already built the logger by then, so " \
                 "this shape is a silent no-op — studio-engine's CHANGELOG 0.33.0 says exactly that. If the " \
                 "engine genuinely moved to an unordered initializer, fix the engine, not this test.")

    refute_match(/app\.config\.logger\s*=/, body,
                 "#{KICKOFF} assigns `app.config.logger`. That was the original defect: the shipped engine " \
                 "sets `config.log_file_size` and lets Rails BUILD the logger, keeping ownership of the path, " \
                 "formatter, level and tagging.")
  end

  test "[static] the kickoff states the ordering and the knob that actually ship" do
    body = prescribed_ruby

    assert_includes body, "before: :initialize_logger",
                    "#{KICKOFF} no longer names the ordering that makes the cap work at all. The ordering IS " \
                    "the mechanism; a version of this doc without it is the version that taught the no-op."
    assert_includes body, "config.log_file_size",
                    "#{KICKOFF} no longer names `config.log_file_size` — the knob :initialize_logger reads"
  end

  # The counterpart to the two scans above. They grade the ```ruby blocks, so a
  # doc that silently dropped its explanation would pass both. This one asks the
  # PROSE to keep saying why the ordering matters — the single fact whose absence
  # let the original recipe read as correct for its whole life.
  test "[static] the kickoff still explains why an unordered initializer is a no-op" do
    body = collapsed(kickoff)

    assert_match(/silent no-op/i, body,
                 "#{KICKOFF} no longer says that an unordered `studio.logger` initializer is a silent no-op. " \
                 "The code block can be correct while the doc stops explaining WHY, and the next person to " \
                 "reflow this file would have no reason to keep the ordering.")
    assert_match(/bootstrap/i, body,
                 "#{KICKOFF} no longer names :initialize_logger as a BOOTSTRAP initializer — the mechanism " \
                 "that makes an ordinary engine initializer too late to matter")
  end

  # ── THE FLOOR CLAIM AGREES WITH THE AUDIT ───────────────────────────────────

  test "[static] the documented cap floor is the one the hub audit enforces" do
    floor = derived_cap_floor

    assert_includes collapsed(kickoff), floor,
                    "#{KICKOFF} does not name #{floor}, the floor ArtifactSweep::ENGINE_CAP_FLOOR tells loose " \
                    "apps they need. The doc and the audit must not name different floors — two authorities " \
                    "disagreeing about this number is what this task existed to end."
  end

  # ── NO REINTRODUCED CURRENT-VERSION CLAIM ───────────────────────────────────
  #
  # The CLAIM is pinned, not the token. The doc legitimately names `0.33.0` (the
  # release the cap shipped in — a permanent fact) and `v0.6.1` (a historical
  # illustration of this exact rot). What must never come back is a present-tense
  # sentence asserting where the gem is TODAY, which is a promise to hand-edit
  # prose on every release — a promise this ecosystem has now broken twice.
  test "[static] the kickoff makes no present-tense claim about the engine's current version" do
    hits = kickoff.lines.each_with_index.filter_map do |_, i|
      window = collapsed(kickoff.lines[i, 2].join)
      next unless window.match?(/[Ee]ngine is at\s+`?v?\d+\.\d+/)

      "#{KICKOFF}:#{i + 1} — #{window[0, 120]}"
    end

    assert_empty hits,
                 "a present-tense \"engine is at <version>\" claim is back. It rotted from 0.32.3 while the " \
                 "gem reached 0.76.x, and studio-engine's own README and docs/RELEASE.md deliberately name no " \
                 "current version for this reason. Point at lib/studio/version.rb or RubyGems instead:\n  " +
                 hits.join("\n  ")
  end

  # ── DELIVERED WORK IS NOT STILL LISTED AS PENDING ───────────────────────────

  test "[static] the kickoff does not promise an Exit Seam the archive SOP already delivers" do
    seam = read(ARCHIVE_SOP)
    # Bounded at the NEXT heading, not at EOF. A greedy slice swallows every
    # section below, so bullets RE-HOMED out of the Exit Seam would still be
    # found and this cross-check would report them present. Measured in review
    # 2026-09-22: moved under `## Related`, the greedy form stayed green.
    seam_body = collapsed(seam[/^## Exit Seam.*?(?=\n## |\z)/m].to_s)

    assert_operator seam_body.length, :>, 200,
                    "could not slice an Exit Seam out of #{ARCHIVE_SOP} — the anchor moved and this " \
                    "cross-check is grading an empty string"

    # The two deliverables this brief listed as future work.
    assert_includes seam_body, "rotation_verdict",
                    "#{ARCHIVE_SOP}'s Exit Seam no longer reports the rotation verdict. If that was removed " \
                    "deliberately, the kickoff's Definition of done is pending again and should say so."
    assert_includes seam_body, "retired-doc count",
                    "#{ARCHIVE_SOP}'s Exit Seam no longer reports retired-doc count"

    done = kickoff[/^## Definition of done.*?(?=\n## |\z)/m]
    assert done, "#{KICKOFF} lost its Definition of done section"
    assert_match(/delivered/i, collapsed(done),
                 "#{ARCHIVE_SOP} delivers the Exit Seam this brief asked for, but #{KICKOFF}'s Definition of " \
                 "done does not record it as delivered. A shipped brief that still reads as a work order " \
                 "invites an agent to rebuild what exists.")
  end
end
