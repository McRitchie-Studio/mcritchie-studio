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

  # bare `bin/<hub-only script>`, optional subcommand words, then an OPERAND —
  # an interpolation (`#{`) or a `<placeholder>`. The negative lookbehind keeps
  # an already-absolute path (".../bin/ship") from matching.
  INSTRUCTION_RE = /(?<![\/\w-])bin\/(#{HUB_ONLY.join('|')})\b((?:\s+[a-z][a-z0-9:_-]*)*)\s+(?:\#\{|<[a-z])/

  # The files this guard sweeps — the scripts that print the most remedies, all
  # routed through FastLane.remedy_command by remedy-hints-print-bare-paths.
  # bin/lib/fast_cert.rb composes both certs' zero-evidence refusals; lib/claim_holder.rb
  # composes the claim refusal BOTH bin/ship and bin/task print — this sweep found two
  # bare `bin/task review-claim …` lines there that a file-by-file read had missed,
  # which is the argument for sweeping the composer and not only the caller.
  #
  # NOT YET SWEPT, and deliberately so — filed with measured counts rather than half-done:
  # bin/task (9 remaining instruction sites), bin/pr-review (3), bin/lib/ci_gate.rb (3),
  # bin/lib/ci_status.rb (1), bin/session-preflight, bin/release.rb. Add a file here as it
  # is cleaned; the sweep is the thing that keeps it clean afterwards.
  SWEPT = %w[bin/ship bin/fast-check bin/full-suite-check bin/dor-check
             bin/lib/fast_cert.rb lib/claim_holder.rb].freeze

  # Bare-and-CORRECT sites, each with the reason it is not an instruction. Keyed on
  # a regex over the line's own text (see the header) so an edit elsewhere in the
  # file cannot invalidate it.
  EXEMPT = [
    # --- usage banners ---------------------------------------------------------
    # A usage line names the command the reader JUST TYPED; it is a synopsis of
    # this script's own grammar, not a command handed over to run. Absolutising it
    # would print a 90-character path in front of every flag list. The right fix
    # for the whole class is `$PROGRAM_NAME`, which is a separate change across
    # ~25 banners in 8 scripts — filed, not folded in here.
    { file: "bin/ship", match: /o\.banner = "Usage: bin\/ship/, why: "usage banner (self-synopsis)" },
    { file: "bin/ship", match: /die!\("usage: bin\/ship/, why: "usage banner (self-synopsis)" },
    { file: "bin/fast-check", match: /o\.banner = "Usage: bin\/fast-check/, why: "usage banner (self-synopsis)" },
    { file: "bin/full-suite-check", match: /o\.banner = "Usage: bin\/full-suite-check/,
      why: "usage banner (self-synopsis)" },
    { file: "bin/dor-check", match: /o\.banner = "Usage: bin\/dor-check/, why: "usage banner (self-synopsis)" },
    { file: "bin/dor-check", match: /die!\("usage: bin\/dor-check/, why: "usage banner (self-synopsis)" },

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
    { file: "bin/dor-check", match: /gate_sops = \[\{ "sop" => "dor-check"/, why: "board-recorded gate evidence, not a hint" }
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
      '"(bin/task update <slug> --pr-url-for <repo>=<url>)"'
    ]
    prose = [
      'abort "... could not be read (bin/task show), so the receipt ..."',
      '"bin/dor-check credits this receipt only alongside a GREEN CI"',
      'die!("bin/fast-check did NOT certify — read its output above.")',
      '"another bin/release is deploying from that checkout"',
      '"which is what bin/reviewer-select reads to keep a soul off their own PR"',
      # already absolute — the fixed form must never re-trip the guard
      'warn "Re-run #{SELF_CMD} #{slug}."',
      'warn "Re-run /Users/x/mcritchie-studio/bin/fast-check #{slug}."'
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
