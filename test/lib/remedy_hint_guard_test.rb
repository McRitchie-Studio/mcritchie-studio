# frozen_string_literal: true

# [unit][integration] THE REMEDY HINTS THE FAST-LANE SCRIPTS PRINT MUST RESOLVE.
#
# THE DEFECT THIS CLOSES. bin/ship, bin/fast-check, bin/full-suite-check,
# bin/dor-check and bin/task live in mcritchie-studio/bin ALONE — no satellite
# (turf-monster, rolio) and no gem (studio-engine, solana-studio, turf-vault)
# carries any of them. A builder on one of those desks therefore reached the
# script through its ABSOLUTE path, because that is the only way they could have
# reached it. Every refusal that then told them to "Re-run bin/fast-check <slug>"
# handed back a command their checkout cannot execute: `No such file or
# directory`, from the tool's own hint, at the exact moment they were already
# stuck. PR #1334 fixed the sentence in the entry docs; PR #1341 fixed
# `bin/task begin`'s handoff line and built FastLane.handoff_command; this pins
# the class across the scripts that print the most of them.
#
# ── WHAT THIS GUARD IS FOR: TELLING AN INSTRUCTION FROM PROSE ────────────────
#
# Not every `bin/x` in a message is a command. These scripts also NAME their
# siblings as subjects — "could not be read (bin/task show)", "bin/dor-check
# credits this receipt only alongside a GREEN CI", "bin/fast-check did NOT
# certify", "another bin/release is deploying from that checkout". Absolutising
# those would make every refusal longer and harder to read while fixing nothing,
# because nobody pastes a sentence's subject.
#
# The tell is an OPERAND. An instruction carries the thing the reader is meant to
# paste — the interpolated slug, or a `<placeholder>` — immediately after the
# script and its subcommand. Prose does not. INSTRUCTION_RE below encodes exactly
# that, and it is the reason this guard can sweep whole files without drowning in
# false positives.
#
# ── WHY THE END-TO-END ASSERTION IS KEYED ON THE FILESYSTEM ──────────────────
#
# MEASURED ON PR #1341: a grep-shaped assertion is BLIND to this defect.
# test/lib/task_begin_test.rb:205 asserted `assert_includes out, "bin/ship
# #{SLUG}"` and stayed GREEN when the printed line was mutated back to the bare
# form — because an absolute path CONTAINS that substring
# (".../bin/ship <slug>" includes "bin/ship <slug>"). Several assertions in
# test/lib/ship_test.rb have the same shape and the same blindness. So the
# end-to-end test here does not ask what the line SAYS. It takes the first token
# of the printed command and asks the disk: is that an absolute path, and is it
# `File.executable?`. Only an absolute, real, runnable script can pass, and no
# amount of substring luck can fake it.
#
# ── THE EXEMPTIONS ARE KEYED ON CONTENT, NEVER ON A LINE NUMBER ──────────────
#
# MEASURED ON PR #1341 (the second trap): a 15-line doc insert silently shifted a
# LINE-KEYED exemption registry in test/docs/bounce_holder_rule_docs_test.rb
# (`line: 836` → 849) and reddened two tests that had nothing to do with the
# change. A registry keyed on line numbers is a registry that breaks on every
# insertion above it, so every entry here carries a `match:` regex read against
# the LINE'S TEXT and a `why:` a reader can audit. Move the code and the
# exemption moves with it.

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"
require_relative "../../bin/lib/fast_lane"

class RemedyHintGuardTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  BIN = File.join(REPO, "bin")

  # The hub-only fast-lane scripts. A bare mention of any of these, carrying an
  # operand, is an instruction a non-hub desk cannot run.
  HUB_ONLY = %w[ship fast-check full-suite-check dor-check task session-preflight
                agent-worktree pr-review reviewer-select gh-auth-refresh release].freeze

  # bare `bin/<hub-only script>`, optional subcommand words, then an OPERAND — an
  # interpolation (`#{`), a `<placeholder>`, or a `--flag`. The negative lookbehind
  # keeps an already-absolute path (".../bin/ship") from matching.
  #
  # THE `--flag` ARM WAS ADDED IN WAVE 2, AND IT WAS NOT COSMETIC. The original rule
  # took an operand to be a slug — an interpolation or an angle-bracket placeholder —
  # which is the shape a remedy carrying a TASK has. It is not the only shape a remedy
  # has. `eval "$(bin/gh-auth-refresh --export)"` is the single most-pasted command in
  # the house, it is handed over in exactly the same "run this" register, and it was
  # invisible to this guard: six live sites survived wave 1 untouched in bin/task,
  # bin/dor-check, bin/lib/ci_status.rb (x2) and bin/session-preflight (x2) — inside
  # files wave 1 had already swept and declared clean. An operand rule that cannot see
  # the most common instruction in the corpus is not a definition of "instruction", it
  # is a description of the examples that happened to be in front of us.
  INSTRUCTION_RE =
    /(?<![\/\w-])bin\/(#{HUB_ONLY.join('|')})\b((?:\s+[a-z][a-z0-9:_-]*)*)\s+(?:\#\{|<[a-z]|--[a-z])/

  # The files this guard sweeps. WAVE 1 (remedy-hints-print-bare-paths) routed the four
  # highest-traffic scripts plus the two shared COMPOSERS: bin/lib/fast_cert.rb composes
  # both certs' zero-evidence refusals, and lib/claim_holder.rb composes the claim
  # refusal BOTH bin/ship and bin/task print — sweeping the composer rather than only
  # the caller is what found two bare `bin/task review-claim …` lines a file-by-file
  # read had missed.
  #
  # WAVE 2 (remedy-hints-second-wave) added the six below it: bin/task (9 runnable
  # remedies + 19 usage banners), bin/pr-review (the two commands inside the reviewer
  # SPAWN PROMPT, whose reader is likeliest of all to be on a foreign desk),
  # bin/lib/ci_gate.rb and bin/lib/ci_status.rb (which compose bin/dor-check's CI
  # refusals, so they reach the reader wave 1 already fixed for the cert refusals),
  # bin/session-preflight, and bin/lib/block_recipe.rb (recipes that exist to be PASTED).
  #
  # STILL NOT SWEPT, filed with measured counts rather than half-done — 77 instruction
  # sites, none of them in this task's scope: bin/lib/review_claim_cli.rb (16),
  # bin/agent-worktree (14), bin/lib/agent_worktree_cli.rb (13), bin/reviewer-select (8),
  # bin/release.rb (7 — and MOST are correctly bare, since the conductor runs bin/release
  # from the hub primary by SOP), lib/review_verdict_gate.rb (6), bin/conductor (5),
  # bin/control-check (4), bin/qa-intake (4), lib/archive_holder_guard.rb (4),
  # bin/lib/desk_guard.rb (1), bin/ship-wait (1), lib/open_pr_guard.rb (1).
  # Add a file here as it is cleaned; the sweep is what keeps it clean afterwards.
  SWEPT = %w[bin/ship bin/fast-check bin/full-suite-check bin/dor-check
             bin/lib/fast_cert.rb lib/claim_holder.rb
             bin/task bin/pr-review bin/lib/ci_gate.rb bin/lib/ci_status.rb
             bin/session-preflight bin/lib/block_recipe.rb].freeze

  # THE FLOORS. Everything above asserts an ABSENCE — and an absence is precisely what a
  # BROKEN scanner reports. Point SWEPT at paths that no longer exist, let a file read
  # back truncated, or narrow INSTRUCTION_RE until it matches nothing, and the sweep goes
  # green having proved nothing at all. Measured on the shipped tree 2026-09-09: 103
  # routed sites across 16,391 lines in 12 files. These are FLOORS with headroom, not
  # equalities — routing more remedies must never redden them.
  MINIMUM_SWEPT_FILES = 12
  MINIMUM_SWEPT_LINES = 14_000
  MINIMUM_ROUTED_SITES = 90

  # A remedy that HAS been routed: the helper called directly, or one of the resolved
  # constants interpolated into a message. This is the POSITIVE side of the sweep —
  # what the guard exists to protect, as opposed to what it forbids.
  ROUTED_RE = /FastLane\.(?:remedy_command|resolve_bin|handoff_command)|
               \#\{(?:[A-Za-z_][A-Za-z0-9_]*::)?
               (?:SELF_CMD|TASK_CMD|TASK_COMMAND|FAST_CHECK_CMD|FULL_SUITE_CMD|
                  DOR_CHECK_CMD|SHIP_CMD|GH_AUTH_REFRESH_CMD)\}/x

  # Bare-and-CORRECT sites, each with the reason it is not an instruction. Keyed on
  # a regex over the line's own text (see the header) so an edit elsewhere in the
  # file cannot invalidate it.
  # THE USAGE BANNERS ARE NO LONGER EXEMPT — THEY WERE FIXED.
  #
  # Wave 1 exempted six of them with the note that the right fix for the whole class was
  # `$PROGRAM_NAME` and that it was "filed, not folded in here". remedy-hints-second-wave
  # is that filing, so the exemptions are gone rather than merely re-worded: every banner
  # in the swept set now interpolates $PROGRAM_NAME, which names the program the reader
  # ACTUALLY invoked — absolute when they reached the script absolutely, bare when they
  # typed the bare form. That is the correct answer for a synopsis of the grammar the
  # reader just typed, and it is why a banner never wanted FastLane.remedy_command: a
  # banner is not a command handed over to run, and printing a 90-character path in front
  # of every flag list would be a regression in readability that fixes nothing.
  #
  # It also means the banners left the guard through the FRONT DOOR. They no longer carry
  # a literal `bin/<script>`, so INSTRUCTION_RE simply does not see them — an exemption
  # would now be dead weight, and `test_every_exemption_still_matches_a_real_line` says so.
  EXEMPT = [
    # --- ship's step transcript ------------------------------------------------
    # `say "N/8 <step> — <command>"` ECHOES what ship is about to run, in the same
    # register as its neighbour `say "3/8 push — git push -u origin #{branch}"`.
    # That neighbour is the proof it is a transcript and not a hint: nobody argues
    # `git push` should be absolute. The reader is being told what happened, not
    # what to do; the remedy, when there is one, is the die! line underneath.
    { file: "bin/ship", match: /say "2\/8 cert — running/, why: "step transcript, not a handed-over command" },
    { file: "bin/ship", match: /say "5\/8 record —/, why: "step transcript, not a handed-over command" },
    { file: "bin/ship", match: /say "7\/8 dor — running/, why: "step transcript, not a handed-over command" },
    { file: "bin/ship", match: /say "8\/8 submit —/, why: "step transcript, not a handed-over command" },

    # --- recorded gate evidence ------------------------------------------------
    # `"cmd" => "bin/dor-check <slug> --gate <gate>"` is a FIELD on a GateRun
    # written to the board, read later by reviewers and by /deployments. It records
    # WHICH SOP produced the verdict; it is not addressed to a reader standing
    # anywhere. An absolute path there would stamp one laptop's directory layout
    # into shared, durable records.
    { file: "bin/dor-check", match: /"sop" => "dor-check", "cmd" =>/, why: "board-recorded gate evidence, not a hint" },
    { file: "bin/dor-check", match: /gate_sops = \[\{ "sop" => "dor-check"/, why: "board-recorded gate evidence, not a hint" },

    # --- content of a generated git hook ----------------------------------------
    # bin/full-suite-check's opt-in pre-push installer WRITES a hook file into another
    # repo's .git/hooks, and `bin/full-suite-check --print` is the line it writes (plus
    # the marker it greps that file for, and the sentence telling an operator to add
    # that same line by hand). Bare is not a lapse here, it is REQUIRED, for two
    # independent reasons. (1) Git runs a hook with the cwd at the top of the repo the
    # hook belongs to, so the bare form resolves BY CONSTRUCTION and names that repo's
    # own checker. (2) An absolute path would bake THIS worktree's location into a
    # different repo's hook file — it would still be pointing here after this desk is
    # reclaimed. The marker line has a third reason on top: it is matched against hooks
    # already on disk, so changing its text orphans every hook already installed.
    { file: "bin/full-suite-check", match: /HOOK_MARKER = "# managed by:/,
      why: "marker text matched against hooks already on disk — changing it orphans them" },
    { file: "bin/full-suite-check", match: /"`exec bin\/full-suite-check --print` yourself/,
      why: "names the literal line the operator must add to a hook file, which must stay bare" },
    { file: "bin/full-suite-check", match: /^\s*exec bin\/full-suite-check --print$/,
      why: "body of the generated pre-push hook; git runs it with cwd at that repo's root" },

    # --- text written INTO the board -------------------------------------------
    # Same rule as dor-check's gate evidence, reached from the other direction. This
    # string is not printed to a terminal: it is the `--feedback` BODY of the escalation
    # block bin/pr-review writes to the task (`task_write(["block", slug, …,
    # "--feedback", feedback, …])`), so it is durable, shared content that other agents
    # and Mr. McRitchie read back off the record. An absolute path there would stamp ONE
    # laptop's directory layout into the board permanently — the exact harm the
    # dor-check exemption above exists to prevent. The reader of a board note is not
    # standing in a shell at that moment, and the slug is on the record beside it.
    { file: "bin/pr-review", match: /Read the full trail with: bin\/task bounces/,
      why: "written into the board as block --feedback, not printed to a reader's terminal" }
  ].freeze

  def line_exempt?(file, text)
    EXEMPT.any? { |e| e[:file] == file && text.match?(e[:match]) }
  end

  # --- the sweep ---------------------------------------------------------------

  def test_no_swept_script_prints_a_bare_fast_lane_instruction
    offenders = []
    SWEPT.each do |rel|
      path = File.join(REPO, rel)
      assert File.exist?(path), "#{rel} is gone — repoint SWEPT rather than letting the sweep go quiet"
      File.readlines(path).each_with_index do |line, idx|
        text = line.strip
        next if text.start_with?("#")            # a comment explains; it does not instruct
        next unless line.match?(INSTRUCTION_RE)
        next if line_exempt?(rel, line)

        offenders << "#{rel}:#{idx + 1}  #{text[0, 150]}"
      end
    end

    assert_empty offenders, <<~MSG
      These print a BARE fast-lane command carrying an operand — an instruction a
      builder on a satellite or gem desk cannot run (the script exists only in
      mcritchie-studio/bin). Route it through FastLane.remedy_command, e.g.

        SELF_CMD = FastLane.remedy_command("fast-check", __dir__)
        ... "Re-run \#{SELF_CMD} \#{slug}."

      If the site is genuinely NOT an instruction (a usage banner, a step
      transcript, a board-recorded field), add it to EXEMPT with a `why:` — keyed
      on the LINE'S TEXT, never on its number.

      #{offenders.join("\n")}
    MSG
  end

  # --- the floors: what stops a green sweep from proving nothing ----------------

  def test_the_sweep_reads_a_real_corpus
    assert_operator SWEPT.size, :>=, MINIMUM_SWEPT_FILES,
                    "SWEPT lists #{SWEPT.size} file(s) — a shrunken list is a sweep that stopped looking"

    missing = SWEPT.reject { |rel| File.exist?(File.join(REPO, rel)) }
    assert_empty missing, "swept paths that no longer exist — repoint SWEPT rather than letting the sweep go quiet"

    lines = SWEPT.sum { |rel| File.readlines(File.join(REPO, rel)).size }
    assert_operator lines, :>=, MINIMUM_SWEPT_LINES,
                    "the sweep visited only #{lines} lines across #{SWEPT.size} files. Measured 2026-09-09 at " \
                    "16,391 — a collapse this large means a reader broke, and every ABSENCE asserted above is vacuous"
  end

  # THE POSITIVE SIDE. The sweep forbids the bare form; this asserts the routed form is
  # actually THERE. Deleting every remedy from these files would satisfy the sweep
  # perfectly — no bare instruction can exist in a file that hands back no instructions
  # at all — so an absence-only guard cannot tell a clean sweep from a gutted one.
  def test_the_swept_files_still_carry_their_routed_remedies
    per_file = SWEPT.to_h do |rel|
      [rel, File.readlines(File.join(REPO, rel)).count { |line| line.match?(ROUTED_RE) }]
    end
    total = per_file.values.sum

    assert_operator total, :>=, MINIMUM_ROUTED_SITES,
                    "only #{total} routed remedy site(s) across the swept set (measured 2026-09-09 at 103). " \
                    "Either the routing was torn out, or ROUTED_RE stopped recognising it:\n" \
                    "#{per_file.map { |rel, n| "  #{rel}: #{n}" }.join("\n")}"

    # Named individually because a collapse in ONE file disappears into a healthy total.
    # bin/session-preflight is deliberately absent: wave 2 fixed its usage banners with
    # $PROGRAM_NAME and reworded one prose line, and it routes no remedy of its own.
    %w[bin/ship bin/fast-check bin/full-suite-check bin/dor-check bin/lib/fast_cert.rb
       lib/claim_holder.rb bin/task bin/pr-review bin/lib/ci_gate.rb bin/lib/ci_status.rb
       bin/lib/block_recipe.rb].each do |rel|
      assert_operator per_file.fetch(rel), :>=, 2,
                      "#{rel} carries #{per_file.fetch(rel)} routed remedy site(s) — it was swept because it " \
                      "prints remedies, so this near-zero means the file, not the defect, went away"
    end
  end

  # A CONSTANT CAN BE RE-POINTED AT THE BARE FORM, AND NO SOURCE-TEXT GUARD CAN SEE IT.
  #
  # MEASURED 2026-09-09 while building this wave. Replace
  #   FULL_SUITE_CMD = FastLane.remedy_command("full-suite-check", File.expand_path(".."))
  # with
  #   FULL_SUITE_CMD = "bin/full-suite-check"
  # and EVERY test above stays green. The call sites still read `#{FULL_SUITE_CMD}`, so
  # ROUTED_RE still counts them as routed; the declaration itself carries no OPERAND, so
  # INSTRUCTION_RE correctly declines to read it as an instruction. The refusal then
  # prints the bare form at runtime — the whole defect restored, through the one door a
  # guard that reads SOURCE TEXT cannot watch.
  #
  # So this asks the VALUE. It is the same move the end-to-end test at the bottom makes
  # for what bin/ship PRINTS, applied to what the shared COMPOSERS HOLD — and the
  # composers are where wave 1 argued the leverage is, because bin/dor-check, bin/ship
  # and bin/task all speak through them. (The two SCRIPTS in the swept set cannot be
  # required — they run on load — so their constants are pinned from the outside
  # instead: bin/ship by test_ships_claim_refusal_prints_commands_that_resolve_on_disk
  # below, bin/task by test/lib/task_begin_test.rb's banner and resume assertions.)
  COMPOSED_REMEDY_CONSTANTS = {
    "bin/lib/ci_gate.rb" => ["CiGate", %w[FULL_SUITE_CMD TASK_CMD]],
    "bin/lib/ci_status.rb" => ["CiStatus", %w[FULL_SUITE_CMD]],
    "bin/lib/block_recipe.rb" => ["BlockRecipe", %w[TASK_CMD]],
    "lib/claim_holder.rb" => ["ClaimHolder", %w[TASK_COMMAND]]
  }.freeze

  def test_every_composed_remedy_constant_resolves_to_an_absolute_executable
    checked = 0
    COMPOSED_REMEDY_CONSTANTS.each do |rel, (mod_name, names)|
      require File.join(REPO, rel.sub(/\.rb\z/, ""))
      mod = Object.const_get(mod_name)

      names.each do |const|
        assert mod.const_defined?(const),
               "#{mod_name}::#{const} is gone — repoint this registry rather than letting the check go quiet"
        value = mod.const_get(const).to_s
        script = value.split(" ").first.to_s

        assert_equal File.expand_path(script), script,
                     "#{rel}: #{mod_name}::#{const} is #{value.inspect} — a BARE command, runnable only from " \
                     "a hub desk. Route it through FastLane.remedy_command."
        assert File.executable?(script),
               "#{rel}: #{mod_name}::#{const} names #{script.inspect}, which is not an executable on this disk"
        checked += 1
      end
    end

    assert_equal COMPOSED_REMEDY_CONSTANTS.values.sum { |(_, names)| names.size }, checked,
                 "the registry and the walk disagree — some constant was skipped silently"
  end

  # The sweep is worthless if its regex cannot see the defect it was written for.
  # This drives INSTRUCTION_RE over the exact shapes that shipped, and over the
  # prose that must NOT be flagged — so a future loosening of the regex fails here
  # rather than going quiet in the sweep above.
  def test_the_instruction_regex_separates_an_instruction_from_prose
    instructions = [
      'abort "Re-run bin/fast-check #{slug}."',
      'die!("... then re-run bin/ship #{slug} (it resumes here).")',
      'warn "record by hand: bin/task update #{slug} --checks ..."',
      '"Verify: bin/task show #{slug} -v."',
      'steal_command: "bin/task begin #{slug} --steal"',
      '"(bin/task update <slug> --pr-url-for <repo>=<url>)"',
      # The exact shapes remedy-hints-second-wave found and fixed, in their PRE-FIX form,
      # copied off the lines themselves. A regex narrowed until it stops seeing these is
      # a regex that would have let this whole wave ship — and the sweep would have gone
      # green while doing it.
      '  Re-run: bin/task move #{slug} #{expected_stage}   (if it recurs the board write is failing)',
      'warn!("  Re-run: bin/task merged #{slug} #{expected}   (check ErrorLog / PG connections).")',
      'puts "   stage is #{result[:stage]} → consider: bin/task move #{slug} shipped   (or archived)"',
      '"If the operator already approved in words, record it: bin/task update #{slug} "',
      'puts "  bin/reviewer-select will REFUSE until: bin/task fix-forward #{slug} --agent <soul>"',
      '"Run the DoR gate as `bin/dor-check #{task.fetch("slug")} --gate-role review` so your verdict"',
      '"`bin/task note #{task.fetch("slug")} --comment \"<your finding>\"`, then hand it to the primary."',
      '"`bin/full-suite-check #{slug}`, which runs ci.yml\'s own command (test:system included)"',
      '"Record it: `bin/task update #{slug} --pr-url <url>`.", false]',
      '"certify in full instead: bin/full-suite-check #{cert_task}."',
      "      bin/task block <slug> --kind dependency --agent <agent> \\",
      # THE FLAG-OPERAND SHAPE — invisible to the original rule, six live sites.
      'warn "Usually a stale token: eval \"$(bin/gh-auth-refresh --export)\""',
      'puts "gh auth: STALE -> eval \"$(bin/gh-auth-refresh --export)\""',
      '"then run `eval \"$(bin/gh-auth-refresh --export)\"` and retry the exact check read."'
    ]
    prose = [
      'abort "... could not be read (bin/task show), so the receipt ..."',
      '"bin/dor-check credits this receipt only alongside a GREEN CI"',
      'die!("bin/fast-check did NOT certify — read its output above.")',
      '"another bin/release is deploying from that checkout"',
      '"which is what bin/reviewer-select reads to keep a soul off their own PR"',
      # already absolute — the fixed form must never re-trip the guard
      'warn "Re-run #{SELF_CMD} #{slug}."',
      'warn "Re-run /Users/x/mcritchie-studio/bin/fast-check #{slug}."',
      # AND THE $PROGRAM_NAME BANNERS, which left through the front door: a banner that
      # names the invoked program carries no literal `bin/<script>` for the regex to see,
      # which is why wave 2 could retire six exemptions instead of re-wording them.
      'o.banner = "Usage: #{$PROGRAM_NAME} <task-slug> [-m MESSAGE]"',
      'usage = "usage: #{$PROGRAM_NAME} show <slug> [--json | --verbose|-v]"',
      # the reworded preflight line: a board read that FAILED is a subject, not a command
      'die!("could not read the task record (bin/task show): #{err}") unless ok'
    ]

    instructions.each do |line|
      assert_match INSTRUCTION_RE, line, "must be read as an INSTRUCTION: #{line}"
    end
    prose.each do |line|
      refute_match INSTRUCTION_RE, line, "must be read as PROSE: #{line}"
    end
  end

  # Every exemption must still MATCH something. A stale entry is worse than no
  # entry: it silently widens the hole the sweep is supposed to close.
  def test_every_exemption_still_matches_a_real_line
    dead = EXEMPT.reject do |e|
      path = File.join(REPO, e[:file])
      File.exist?(path) && File.readlines(path).any? { |line| line.match?(e[:match]) }
    end

    assert_empty dead.map { |e| "#{e[:file]}  #{e[:match].inspect}  (#{e[:why]})" },
                 "exemptions that no longer match any line — delete them, or repoint `match:`"
  end

  def test_every_exemption_carries_a_reason
    EXEMPT.each do |e|
      refute_empty e[:why].to_s.strip, "an exemption without a `why:` is a hole nobody can audit: #{e.inspect}"
    end
  end

  # --- the helper --------------------------------------------------------------

  def test_remedy_command_names_an_absolute_executable_for_every_swept_script
    %w[ship fast-check full-suite-check dor-check task].each do |script|
      line = FastLane.remedy_command(script, BIN, "some-task")
      first = line.split(" ").first

      assert_equal File.expand_path(first), first, "#{script}: the remedy must be an ABSOLUTE path, got #{line}"
      assert File.executable?(first), "#{script}: the remedy must name a real executable, got #{line}"
      assert_equal "#{File.join(BIN, script)} some-task", line
    end
  end

  def test_resolve_bin_prefers_the_first_directory_that_actually_carries_the_script
    Dir.mktmpdir do |root|
      desk = File.join(root, "desk", "bin")
      hub = File.join(root, "hub", "bin")
      FileUtils.mkdir_p(desk)
      FileUtils.mkdir_p(hub)
      File.write(File.join(hub, "ship"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(hub, "ship"))

      # the desk has no ship → falls through to the hub's
      assert_equal File.join(hub, "ship"), FastLane.resolve_bin("ship", [desk, hub])

      # give the desk one and it wins — resolution follows the DISK, so onboarding
      # a repo (or shimming a satellite) needs no registry edit anywhere
      File.write(File.join(desk, "ship"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(desk, "ship"))
      assert_equal File.join(desk, "ship"), FastLane.resolve_bin("ship", [desk, hub])
    end
  end

  def test_resolve_bin_still_names_an_absolute_path_when_nothing_exists
    # The reader gets a path they can reason about ("that file is missing")
    # instead of a bare word that hides the question ("which bin/ship?").
    line = FastLane.resolve_bin("ship", ["/nonexistent/a/bin", "/nonexistent/b/bin"])

    assert_equal "/nonexistent/b/bin/ship", line
    assert_equal File.expand_path(line), line
  end

  def test_a_non_executable_file_does_not_win_the_resolution
    Dir.mktmpdir do |root|
      desk = File.join(root, "desk", "bin")
      hub = File.join(root, "hub", "bin")
      FileUtils.mkdir_p(desk)
      FileUtils.mkdir_p(hub)
      File.write(File.join(desk, "ship"), "not executable\n")   # mode 0644
      File.write(File.join(hub, "ship"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(hub, "ship"))

      assert_equal File.join(hub, "ship"), FastLane.resolve_bin("ship", [desk, hub]),
                   "a file that cannot be RUN is not a resolution — `bin/ship` there still fails"
    end
  end

  def test_blank_args_are_dropped_so_a_pasted_command_has_no_double_space
    line = FastLane.remedy_command("task", BIN, "move", "some-task", "", nil, "building")

    assert_equal "#{File.join(BIN, 'task')} move some-task building", line
  end

  def test_the_cert_remedy_is_absolute_in_the_hub_arm_too
    # The hub arm used to return the bare "bin/full-suite-check <task>". It was
    # defensible — CertRootGuard makes the cert writers' cwd agree with `root`, so
    # a hub tree DOES carry the script — but it left one refusal speaking two
    # dialects, and it rested on a guard the FAST_CHECK_ROOT seam bypasses.
    require_relative "../../bin/lib/fast_cert"

    hub = FastCert.remedy("some-task", root: REPO, hub_root: REPO)
    satellite = FastCert.remedy("some-task", root: "/x/turf-monster", hub_root: REPO)

    assert_equal "#{File.join(BIN, 'full-suite-check')} some-task", hub
    assert_equal "#{File.join(BIN, 'full-suite-check')} some-task", satellite
    [hub, satellite].each do |line|
      refute_match(%r{\Abin/}, line, "a bare form is not runnable from a satellite or gem desk")
    end
  end

  # --- end to end: what bin/ship ACTUALLY PRINTS -------------------------------
  #
  # The claim refusal is the highest-traffic remedy in the house and the one that
  # fires EARLIEST — before ship has rooted — so its reader is the most likely to
  # be standing somewhere the bare form cannot resolve. It is also reachable from
  # a test without a board: a task whose lease names another session.
  #
  # The assertion is deliberately not a substring match. It splits the printed
  # command, takes the script, and asks the DISK.
  def test_ships_claim_refusal_prints_commands_that_resolve_on_disk
    Dir.mktmpdir do |root|
      work = File.join(root, "work")
      FileUtils.mkdir_p(work)
      task_bin = write_task_stub(root)

      out, err, status = Open3.capture3(
        ship_env(root, task_bin), File.join(BIN, "ship"), "held-task", chdir: work
      )
      combined = "#{out}\n#{err}"

      refute status.success?, "a task held by another session must refuse:\n#{combined}"
      commands = printed_commands(combined)
      refute_empty commands, "the refusal must hand over a retry and a takeover command:\n#{combined}"

      commands.each do |cmd|
        script = cmd.split(" ").first
        assert_equal File.expand_path(script), script,
                     "the refusal handed over a NON-ABSOLUTE command (#{cmd.inspect}) — a satellite " \
                     "or gem desk cannot resolve it:\n#{combined}"
        assert File.executable?(script),
               "the refusal handed over #{script.inspect}, which is not an executable on this disk:\n#{combined}"
      end

      # and the two remedies it owes are both there, by NAME of the script
      assert commands.any? { |c| c.include?("/bin/ship ") }, "the retry path must be named:\n#{combined}"
      assert commands.any? { |c| c.include?("/bin/task ") }, "the takeover path must be named:\n#{combined}"
    end
  end

  private

  # Every command-looking run in the output: an absolute path under a bin/
  # directory, or a BARE `bin/<script>` — so the assertion above can catch the
  # bare form rather than silently skipping it.
  def printed_commands(text)
    text.scan(%r{(?:/[^\s"']*)?bin/(?:ship|task|fast-check|full-suite-check|dor-check)(?:[ \t]+[^\s"'\n]+)*})
        .map(&:strip).uniq
  end

  # A board CLI stub serving one task: [building], claimed by ANOTHER session with
  # a live lease. That is the state ship's claim gate refuses on.
  def write_task_stub(root)
    path = File.join(root, "task-stub")
    payload = {
      "slug" => "held-task", "stage" => "building", "review_in_progress" => false,
      "metadata" => { "devops" => {
        "claimed_session" => "sess-rival-9999", "claim_nonce" => "inst-A",
        "claim_expires_at" => (Time.now + 300).utc.iso8601
      } }
    }
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "show" ]; then printf '%s' '#{JSON.generate(payload)}'; exit 0; fi
      exit 0
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def ship_env(root, task_bin)
    SessionEnv.neutralized(
      "SHIP_TASK_BIN" => task_bin,
      "SHIP_FAST_CHECK_BIN" => task_bin,
      "SHIP_DOR_CHECK_BIN" => task_bin,
      "SHIP_ACTIVITY_BIN" => task_bin,
      "SHIP_GH_BIN" => task_bin,
      "CLAUDE_PROJECTS_DIR" => root,
      "CLAUDE_CODE_SESSION_ID" => "sess-shipper-1111",
      "TASK_CLAIM_NONCE" => "inst-default"
    )
  end
end
