# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "open3"

# GUARD (guard-credential-rotation-shell, 2026-09-09): the SIBLING guard
# (credential_rotation_sop_docs_test.rb) proves the SOP is REGISTERED and
# STANDALONE — that an agent can resolve the invocation and that no step sends the
# reader out to an unregistered file. That is a registration-and-link-hop guard by
# design, and it passed CLEANLY on a revision of this SOP whose Phase 4 wrote an
# EMPTY value to ten Heroku apps and fifty-seven desk `.env` files, and whose
# Phase 5 then certified the wipe as a success. Both defects were caught by a human
# reviewer with nothing standing behind him.
#
# This guard closes that class. It does not read the prose — it EXECUTES the shell
# the SOP ships, in a sandbox, and grades what the commands DO:
#
#   B1  UNASSIGNED VARIABLE — `$NEW` was expanded at seven sites and assigned at
#       none, so every write in Phase 4 interpolated the empty string. The section
#       header said "Phase 4.1 sets it"; 4.1 set nothing. Prose review reads that
#       header and believes it. `expanded_variables` vs `assigned_variables` does
#       not.
#
#   B2  EMPTY CERTIFIES GREEN — sha256("") is a well-formed digest, and an empty
#       store digests identically to an empty reference, so "filed digest ==
#       $NEW digest" reports MATCH after everything has been emptied. A comparison
#       both sides can satisfy with nothing is not a comparison. The SOP's fix is a
#       `digest` helper that refuses empty input; this guard RUNS it on empty input
#       and requires the refusal.
#
# ── WHY BEHAVIOUR AND NOT A GREP ──────────────────────────────────────────────
#
# A grep for "${NEW:?" would go green on a guard that sits in a section nobody
# copy-pastes, and red on a rewrite that protects the same value a better way.
# What matters is whether the destructive blocks REFUSE. So the harness builds a
# fake projects root with fake desks holding a known value, rewrites the SOP's
# real paths onto it, runs the blocks with `NEW` unset, and asserts the fixtures
# still hold their value — the exact experiment Carl ran by hand when he found B1.
#
# Every "it refused" assertion is paired with a CONTROL run that sets `NEW` and
# requires the same block to WRITE. Without the control, a block that had been
# deleted, renamed, or emptied would "refuse" perfectly and prove nothing.
#
# ── SANDBOX SAFETY ────────────────────────────────────────────────────────────
#
# These blocks rewrite `.env` files and `rm -f` snapshots. The harness rewrites
# PROJECTS_ROOT to a Dir.mktmpdir and then REFUSES TO EXECUTE any script that
# still mentions the real root. That check is a precondition, not an assertion
# about the SOP: if a future edit hardcodes a path the rewrite misses, this test
# fails without running anything.
class CredentialRotationShellGuardTest < ActiveSupport::TestCase
  SOP = Rails.root.join("docs/agents/agents/steffon/sops/credential-rotation.md")

  PROJECTS_ROOT = "/Users/alex/projects"
  FIXTURE_VAR   = "GUARD_FIXTURE_SECRET"
  LIVE_VALUE    = "live-value-that-must-survive-an-unset-NEW"
  NEW_VALUE     = "freshly-minted-guard-fixture-value"
  EMPTY_SHA256  = Digest::SHA256.hexdigest("")

  FIXTURE_ITEM  = "guard-fixture-item"
  FIXTURE_VAULT = "guard-fixture-vault"
  FIXTURE_FIELD = "guard-fixture-field"

  # Squads fixture identities for the step-5 grader. Deliberately not real pubkeys:
  # the grader compares strings, and a real address in a test invites someone to
  # believe the test talked to mainnet. It does not — see that test's comment.
  NEW_MEMBER    = "GuardFixtureNewMember"
  OLD_MEMBER    = "GuardFixtureOldMember"
  KEEP_MEMBER_A = "GuardFixtureSurvivorA"
  KEEP_MEMBER_B = "GuardFixtureSurvivorB"

  # Every angle-bracket placeholder the harness knows how to make safe. Substituted
  # before execution, and anything left over REFUSES the run: `--vault <vault>` is
  # not a literal to bash, it is a REDIRECT PAIR — it would read a file named
  # `vault` and CREATE one named `<field>[concealed]=<the value>`. A placeholder
  # this map has not learned about must stop the harness, not be executed.
  PLACEHOLDERS = {
    "<VAR>"        => FIXTURE_VAR,
    "<item>"       => FIXTURE_ITEM,
    "<vault>"      => FIXTURE_VAULT,
    "<field>"      => FIXTURE_FIELD,
    "<new pubkey>" => NEW_MEMBER,
    "<old pubkey>" => OLD_MEMBER
  }.freeze

  UNSUBSTITUTED = /<[a-z][a-z _]*>/i

  # The SOP's WRITE lanes: every heading whose fenced shell mutates a real store
  # from `$NEW`, with the substring that picks its writing blocks out and the count
  # there must be. BOTH behavioural lanes below iterate this map.
  #
  # 4.2 was uncovered until 2026-09-09. Its `op item edit` guard was correctly
  # chained in the shipped text, but no test EXECUTED it — so zap 5b292c36's claim
  # that "un-chaining any guard turns it red" was false for exactly one guard, and
  # a coverage claim that is false is worse than a missing one, because it is
  # believed. Adding a lane here is how a new write earns the same grading.
  WRITE_LANES = {
    "### 4.2 File it in 1Password FIRST" => ["op item edit", 1],
    "### 4.4 Write the runtime stores"   => ["$NEW", 2]
  }.freeze

  # What counts as MUTATING a store. Any fenced block matching this must live under
  # a WRITE_LANES heading, so the coverage claim cannot quietly go false again —
  # see the test at the bottom of this file.
  MUTATING = /heroku config:set|heroku config:unset|op item edit|op item create|\brm -f\b|\bmv\b|>>[ \t]/

  # Names a snippet may expand without assigning, each with the reason it is
  # supplied from outside the SOP. Anything NOT on this list must be assigned by
  # the SOP itself — that is the B1 property.
  EXTERNALLY_PROVIDED = {
    "TMPDIR" => "set by the OS for every login shell",
    "T"      => "Mr. McRitchie's OWN shell variable, assigned by credential-filing §5 in HIS terminal. " \
                "The SOP names it only to say that shell is a DIFFERENT one — which is precisely why " \
                "$NEW must be assigned in the rotating shell and cannot be inherited from his."
  }.freeze

  # ── extraction ────────────────────────────────────────────────────────────

  # Every fenced ```bash block, tagged with the nearest preceding heading. The
  # heading is the handle the behavioural tests select on; each of them asserts
  # its heading was found, so a renamed section fails loudly instead of selecting
  # an empty set and passing.
  def bash_blocks
    @bash_blocks ||= begin
      blocks = []
      heading = "(none)"
      buf = nil
      SOP.read.each_line do |line|
        if buf
          if line.start_with?("```")
            blocks << { heading: heading, body: buf.join }
            buf = nil
          else
            buf << line
          end
        elsif line.start_with?("```bash")
          buf = []
        elsif line.start_with?("#")
          heading = line.chomp
        end
      end
      blocks
    end
  end

  def blocks_under(heading)
    found = bash_blocks.select { |b| b[:heading] == heading }
    refute_empty found,
                 "no ```bash block found under the heading #{heading.inspect}. Either the section was " \
                 "renamed or its commands stopped being fenced as bash — and this test would then grade " \
                 "an empty set. Point the constant at the new heading."
    found
  end

  # The writing blocks of one WRITE_LANES heading, with the count assertion inline
  # so a lane that loses its write fails loudly instead of grading an empty set.
  def write_blocks(heading)
    needle, expected = WRITE_LANES.fetch(heading)
    found = blocks_under(heading).select { |b| b[:body].include?(needle) }

    assert_operator found.length, :>=, expected,
                    "only #{found.length} of #{heading.inspect}'s bash blocks contain #{needle.inspect}, " \
                    "expected at least #{expected}. Either the write was removed, or it now writes the " \
                    "value some other way this guard cannot see — and the refusal assertions below would " \
                    "then grade an empty set and pass on nothing."
    found
  end

  def fenced_text
    @fenced_text ||= bash_blocks.map { |b| b[:body] }.join("\n")
  end

  # Inline `code spans` count as EXPANSION sites: a one-line command in prose runs
  # exactly like a fenced one, and B1's worst site (`heroku config:set
  # "<VAR>=$NEW"`) would have been just as lethal inline.
  #
  # They deliberately do NOT count as ASSIGNMENT sites. Prose quotes command
  # OUTPUT in backticks too — `keys=0`, `has=` — and counting those as assignments
  # let three names into the assigned set that nothing assigns. An unassigned
  # variable would then be excused by a sentence describing what a command prints.
  # Assignments are read from the fenced blocks only, which is where a reader can
  # actually copy one.
  def inline_text
    @inline_text ||= SOP.read.scan(/`([^`\n]+)`/).flatten.join("\n")
  end

  def expanded_variables(text)
    text.scan(/\$\{?([A-Za-z_][A-Za-z0-9_]*)/).flatten.uniq
  end

  def assigned_variables(text)
    names = []
    names += text.scan(/(?:\A|[\n;&|(]|\bexport\s+|\blocal\s+)[ \t]*([A-Za-z_][A-Za-z0-9_]*)=/).flatten
    names += text.scan(/\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/).flatten
    names += text.scan(/(?:\A|[\n;&|(])[ \t]*read\s+(?:-\S+\s+)*([A-Za-z_][A-Za-z0-9_]*)/).flatten
    names += text.scan(/\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\b/).flatten
    names.uniq
  end

  # ── B1, statically: nothing is expanded that the SOP never sets ────────────

  test "no shell variable is expanded by the SOP without the SOP assigning it" do
    assert_operator bash_blocks.length, :>=, 8,
                    "only #{bash_blocks.length} bash blocks parsed out of the SOP — the fence scanner has " \
                    "gone blind and every assertion in this file would grade an empty corpus"

    expanded = (expanded_variables(fenced_text) + expanded_variables(inline_text)).uniq

    assert_operator expanded.length, :>=, 6,
                    "only #{expanded.length} variable expansions found across the SOP's shell — the " \
                    "expansion regex has stopped matching and this assertion would pass on nothing"

    assigned = assigned_variables(fenced_text)

    assert_operator assigned.length, :>=, 5,
                    "only #{assigned.length} assignments found in the SOP's fenced blocks — the " \
                    "assignment regex has gone blind, which would report every variable as an orphan"

    orphans  = expanded - assigned - EXTERNALLY_PROVIDED.keys

    assert_empty orphans,
                 "these variables are EXPANDED by the SOP's commands but never ASSIGNED by it: " \
                 "#{orphans.inspect}. Every one of them interpolates the empty string for the reader who " \
                 "runs the file top to bottom — which is how a rotation writes `#{FIXTURE_VAR}=` to ten " \
                 "apps and fifty-seven desks while every command exits 0. Assign it in the phase that " \
                 "introduces it, or add it to EXTERNALLY_PROVIDED with the reason it comes from outside."

    # The allowlist is not a free pass: an entry nothing expands any more is an
    # allowance nobody is reviewing.
    stale = EXTERNALLY_PROVIDED.keys - expanded

    assert_empty stale,
                 "EXTERNALLY_PROVIDED names variables the SOP no longer uses: #{stale.inspect}. Remove " \
                 "them, or the list quietly widens what this guard permits."

    # And the property is only meaningful if $NEW — the variable every write
    # interpolates — is actually one of the ones being graded.
    assert_includes expanded, "NEW", "the SOP stopped expanding $NEW; re-point this guard at whatever replaced it"
    assert_includes assigned, "NEW",
                    "the SOP expands $NEW but never assigns it. This is defect B1 verbatim: Phase 4 then " \
                    "writes an empty value to every store on the Phase 1 list, and exits 0 doing it."
  end

  # ── the sandbox ───────────────────────────────────────────────────────────

  # A fake projects root: two desks holding the credential at a known value, plus
  # one pre-rotation and one post-rotation env snapshot.
  def build_sandbox(dir)
    %w[mcritchie-studio turf-monster].each do |app|
      desk = File.join(dir, app, ".worktrees", "some-desk")
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".env"), "OTHER_KEY=untouched\n#{FIXTURE_VAR}=#{LIVE_VALUE}\n")
    end

    tmp = File.join(dir, "mcritchie-studio", "tmp")
    FileUtils.mkdir_p(tmp)
    File.write(File.join(tmp, "env-snapshot-2026-09-01.json"), '{"captured_at":"2026-09-01T00:00:00Z","apps":{}}')
    File.write(File.join(tmp, "env-snapshot-2026-09-09.json"), '{"captured_at":"2026-09-09T23:00:00Z","apps":{}}')

    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)

    # One stub per external writer the SOP's blocks call. Each records its argv and
    # writes nothing, so a block that SHOULD have refused is caught by the call it
    # made rather than by the damage it did.
    { "heroku" => "heroku.log", "op" => "op.log" }.each do |cmd, log|
      path = File.join(bin, cmd)
      File.write(path, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{File.join(dir, log)}\"\n")
      FileUtils.chmod(0o755, path)
    end

    dir
  end

  def desk_envs(dir)
    Dir.glob(File.join(dir, "*", ".worktrees", "*", ".env"))
  end

  # Rewrites the SOP's real paths and its <VAR> placeholder onto the sandbox, then
  # REFUSES to run anything still pointing at the real projects root.
  # Path + placeholder rewriting, with the two preconditions that make execution
  # safe. SHARED by both behavioural lanes so they cannot drift: the interactive
  # lane used to do its own `<VAR>`-only rewrite, which would have handed a live
  # `--vault <vault>` redirect to a real shell.
  def safe_script(body, dir)
    script = PLACEHOLDERS.reduce(body.gsub(PROJECTS_ROOT, dir)) { |acc, (k, v)| acc.gsub(k, v) }

    refute_includes script, PROJECTS_ROOT,
                    "REFUSING TO EXECUTE: after path rewriting this snippet still references #{PROJECTS_ROOT}. " \
                    "Running it would rewrite real `.env` files and delete real env snapshots. Fix the " \
                    "rewrite in this test before touching anything else."

    leftover = script[UNSUBSTITUTED]

    assert_nil leftover,
               "REFUSING TO EXECUTE: this snippet still contains the placeholder #{leftover.inspect}. " \
               "bash does not treat that as a literal — `--vault <vault>` is a redirect pair that reads " \
               "a file named `vault` and creates one named after the rest of the line. Teach PLACEHOLDERS " \
               "what to substitute before this block can be graded."

    script
  end

  def run_block(body, dir, env)
    script = safe_script(body, dir)

    full_env = { "PATH" => "#{File.join(dir, 'bin')}:#{ENV['PATH']}" }.merge(env)
    stdout, stderr, status = Open3.capture3(full_env, "bash", "-c", script, unsetenv_others: false, chdir: dir)
    { out: stdout, err: stderr, status: status.exitstatus, script: script }
  end

  def heroku_calls(dir)
    stub_calls(dir, "heroku.log")
  end

  def op_calls(dir)
    stub_calls(dir, "op.log")
  end

  def stub_calls(dir, log)
    path = File.join(dir, log)
    File.exist?(path) ? File.readlines(path).map(&:chomp) : []
  end

  # ── B1, behaviourally: the writes refuse, and the control proves they can write

  test "every WRITE lane REFUSES to run with $NEW unset, and still writes when it is set" do
    lanes = WRITE_LANES.keys.to_h { |heading| [heading, write_blocks(heading)] }

    # ── the refusal ────────────────────────────────────────────────────────
    Dir.mktmpdir("crs-refuse") do |dir|
      build_sandbox(dir)
      env = { "APPS" => "fixture-app-one fixture-app-two", "ROTATED_AT" => "2026-09-09T12:00:00Z" }

      lanes.each do |heading, blocks|
        blocks.each do |block|
          result = run_block(block[:body], dir, env)

          refute_equal 0, result[:status],
                       "a write block under #{heading} ran to SUCCESS with $NEW unset. It wrote " \
                       "the empty string into a real store and reported nothing wrong. Open the block with " \
                       ": \"${NEW:?...}\" so it refuses.\n--- script ---\n#{result[:script]}"
        end
      end

      # 4.2's store. The guard is CHAINED to the write, so the refusal is not
      # "op wrote an empty field" — it is that `op` was never reached at all.
      edits = op_calls(dir).select { |c| c.include?("item edit") }

      assert_empty edits,
                   "`op item edit` was reached with $NEW unset: #{edits.inspect}. On the real vault that " \
                   "overwrites the live 1Password field with the empty string — the ONE store Phase 4.2 " \
                   "calls reversible, and the one every later comparison reads back as the reference."

      desk_envs(dir).each do |file|
        assert_includes File.read(file), "#{FIXTURE_VAR}=#{LIVE_VALUE}",
                        "#{file} lost its live value to a Phase 4.4 block run with $NEW unset. This is " \
                        "defect B1's blast radius: fifty-seven desk `.env` files stripped to a bare " \
                        "`#{FIXTURE_VAR}=`, every command exiting 0.\nFile now:\n#{File.read(file)}"
      end

      emptied = heroku_calls(dir).select { |c| c.include?("#{FIXTURE_VAR}=") && c =~ /#{FIXTURE_VAR}=(\s|$)/ }

      assert_empty emptied,
                   "heroku config:set was called with an EMPTY value: #{emptied.inspect}. On the real " \
                   "fleet that blanks the credential on every app in the list."
    end

    # ── the control: the same blocks MUST write when $NEW is set ────────────
    Dir.mktmpdir("crs-control") do |dir|
      build_sandbox(dir)
      env = {
        "NEW" => NEW_VALUE,
        "APPS" => "fixture-app-one fixture-app-two",
        "ROTATED_AT" => "2026-09-09T12:00:00Z"
      }

      lanes.each_value { |blocks| blocks.each { |block| run_block(block[:body], dir, env) } }

      filed = op_calls(dir).select { |c| c.include?("item edit") && c.include?("#{FIXTURE_FIELD}[concealed]=#{NEW_VALUE}") }

      assert_operator filed.length, :>=, 1,
                      "with $NEW set, no `op item edit … #{FIXTURE_FIELD}[concealed]=<value>` reached the " \
                      "stub. The 4.2 refusal above is then VACUOUS — a block that never writes refuses " \
                      "perfectly and proves nothing. Calls seen: #{op_calls(dir).inspect}"

      rewritten = desk_envs(dir).select { |f| File.read(f).include?("#{FIXTURE_VAR}=#{NEW_VALUE}") }

      assert_operator rewritten.length, :>=, 2,
                      "with $NEW set, only #{rewritten.length} of #{desk_envs(dir).length} sandbox desk " \
                      "`.env` files were rewritten. The refusal above therefore proves NOTHING — a block " \
                      "that never writes refuses perfectly. Fix the harness or the desk loop."

      calls = heroku_calls(dir)

      assert(calls.any? { |c| c.include?("config:set") && c.include?("#{FIXTURE_VAR}=#{NEW_VALUE}") },
             "with $NEW set, no `heroku config:set #{FIXTURE_VAR}=<value>` reached the stub. The refusal " \
             "assertion above is then vacuous. Calls seen: #{calls.inspect}")

      desk_envs(dir).each do |file|
        assert_includes File.read(file), "OTHER_KEY=untouched",
                        "the desk loop clobbered an unrelated line in #{file}; it must replace only its own"
      end
    end
  end

  # ── B1, in the shell the OPERATOR actually uses ────────────────────────────
  #
  # The refusal test above runs each block with `bash -c` — a NON-interactive
  # shell, where an unset `${NEW:?...}` aborts. The SOP is pasted into an
  # INTERACTIVE shell, which does NOT abort: it prints the refusal and runs the
  # next line anyway. Measured 2026-09-09: with the guard on its own line, both
  # `zsh -i` and `bash -i` stripped every fixture `.env` to a bare `<VAR>=` while
  # the guard "refused". So this asserts the property in the shell that matters —
  # otherwise the fix ships with the same blind spot as the bug.
  test "every WRITE lane refuses in an INTERACTIVE shell, not only in a script" do
    lanes = WRITE_LANES.keys.to_h { |heading| [heading, write_blocks(heading)] }

    %w[bash zsh].each do |sh|
      next unless system("command -v #{sh} > /dev/null 2>&1")

      Dir.mktmpdir("crs-interactive-#{sh}") do |dir|
        build_sandbox(dir)

        lanes.each_value do |blocks|
          blocks.each do |block|
            env = { "PATH" => "#{File.join(dir, 'bin')}:#{ENV['PATH']}", "APPS" => "fixture-app-one" }
            Open3.capture3(env, sh, "-i", stdin_data: safe_script(block[:body], dir),
                           unsetenv_others: false, chdir: dir)
          end
        end

        desk_envs(dir).each do |file|
          assert_includes File.read(file), "#{FIXTURE_VAR}=#{LIVE_VALUE}",
                          "#{file} was stripped by a Phase 4.4 block pasted into an INTERACTIVE #{sh} " \
                          "with $NEW unset. `${NEW:?...}` on its own line does not stop an interactive " \
                          "shell — chain it to the write with `&&` so the refusal skips the write.\n" \
                          "File now:\n#{File.read(file)}"
        end

        emptied = heroku_calls(dir).select { |c| c =~ /#{FIXTURE_VAR}=(\s|$)/ }

        assert_empty emptied, "interactive #{sh}: heroku config:set ran with an EMPTY value: #{emptied.inspect}"

        edits = op_calls(dir).select { |c| c.include?("item edit") }

        assert_empty edits,
                     "interactive #{sh}: `op item edit` was reached with $NEW unset: #{edits.inspect}. " \
                     "An interactive shell does not abort on `${NEW:?…}`; it prints and runs the next " \
                     "command. Chain the guard to the write with `&&` so the refusal skips it."
      end
    end
  end

  # ── the snapshot delete keeps the post-rotation fallback ───────────────────

  test "the env-snapshot sweep deletes pre-rotation snapshots and KEEPS the post-rotation one" do
    block = blocks_under("### 4.4 Write the runtime stores").find { |b| b[:body].include?("env-snapshot-") }

    refute_nil block,
               "Phase 4.4 no longer has a bash block touching env-snapshot-*.json. If snapshot cleanup " \
               "moved, re-point this test; if it went back to a bare `rm -f …env-snapshot-*.json`, that " \
               "glob deletes the post-rotation fallback ecosystem-build just wrote."

    Dir.mktmpdir("crs-snap") do |dir|
      build_sandbox(dir)
      # ROTATED_AT sits between the two fixture snapshots.
      result = run_block(block[:body], dir, { "ROTATED_AT" => "2026-09-09T12:00:00Z" })
      tmp = File.join(dir, "mcritchie-studio", "tmp")

      assert_equal 0, result[:status],
                   "the snapshot sweep failed to run.\nstderr: #{result[:err]}\n--- script ---\n#{result[:script]}"

      refute File.exist?(File.join(tmp, "env-snapshot-2026-09-01.json")),
             "the pre-rotation snapshot survived the sweep — it still holds the dead value"

      assert File.exist?(File.join(tmp, "env-snapshot-2026-09-09.json")),
             "the sweep deleted the POST-rotation snapshot (captured_at 2026-09-09T23:00:00Z, after " \
             "ROTATED_AT). That file is the Heroku-independent fallback the rotation just created, and " \
             "the deletion is irreversible. A date-globbing `rm -f` does exactly this."
    end

    # And it must refuse without the stamp that tells it which side is which.
    Dir.mktmpdir("crs-snap-unstamped") do |dir|
      build_sandbox(dir)
      result = run_block(block[:body], dir, {})
      tmp = File.join(dir, "mcritchie-studio", "tmp")

      refute_equal 0, result[:status],
                   "the snapshot sweep ran with no ROTATED_AT stamp. With nothing to compare against it " \
                   "cannot tell a stale snapshot from the fresh one, so it must refuse."
      assert File.exist?(File.join(tmp, "env-snapshot-2026-09-09.json")),
             "the unstamped snapshot sweep deleted files anyway"
    end
  end

  # ── B2, behaviourally: the comparison cannot pass on nothing ───────────────

  test "the SOP's digest helper REFUSES an empty value instead of certifying it" do
    helper = blocks_under("### Compare by digest — and a digest of nothing is not a comparison")
             .find { |b| b[:body].include?("digest()") }

    refute_nil helper,
               "the SOP no longer defines a `digest()` helper under its digest heading. Without one, every " \
               "comparison in Phases 4 and 5 is a bare `shasum`, and sha256(\"\") == sha256(\"\") reports " \
               "MATCH between an emptied store and an empty reference — defect B2."

    Dir.mktmpdir("crs-digest") do |dir|
      # EMPTY input: no digest, non-zero exit.
      empty = run_block("#{helper[:body]}\nprintf '%s' '' | digest\n", dir, {})

      refute_equal 0, empty[:status],
                   "`digest` accepted an empty value and exited 0. Phase 5 then compares two empty sides, " \
                   "reports MATCH, and certifies a rotation that wiped every store it touched."
      refute_includes empty[:out], EMPTY_SHA256[0, 16],
                      "`digest` printed the empty-string digest #{EMPTY_SHA256[0, 16]}… on empty input. A " \
                      "digest that an empty value can produce is a digest an empty value can MATCH."
      assert_empty empty[:out].strip,
                   "`digest` printed something on empty input: #{empty[:out].inspect}. Whatever it is, a " \
                   "later comparison will treat it as a value."

      # NON-EMPTY input: a real digest, and it is not the empty one.
      real = run_block("#{helper[:body]}\nprintf '%s' '#{NEW_VALUE}' | digest\n", dir, {})

      assert_equal 0, real[:status],
                   "`digest` rejected a legitimate value — the refusal above then proves only that the " \
                   "helper is broken.\nstderr: #{real[:err]}"

      # Pin correctness against Ruby, so the guard does not inherit a wrong shasum.
      expected = Digest::SHA256.hexdigest(NEW_VALUE)

      assert_equal expected[0, real[:out].strip.length], real[:out].strip,
                   "`digest` printed #{real[:out].strip.inspect}, which is not a prefix of " \
                   "sha256(#{NEW_VALUE.inspect}). The helper is not digesting what it was given."
      refute_equal EMPTY_SHA256[0, real[:out].strip.length], real[:out].strip,
                   "a real value digested to the EMPTY-string digest"
    end
  end

  # The reader needs to recognise the empty digest when a bare `shasum` produces
  # one, so the SOP must name it — and this asserts the constant is CORRECT, not
  # merely present.
  test "the SOP names the true sha256 of the empty string" do
    assert_includes SOP.read, EMPTY_SHA256,
                    "the SOP does not name sha256(\"\") = #{EMPTY_SHA256}. An operator who runs a bare " \
                    "`shasum` during triage needs to recognise that value on sight; it is what an unset " \
                    "config var, a stripped `.env` line, and a failed read all produce."
  end

  # ── Finding A: step 5's Squads check must be able to FAIL ─────────────────
  #
  # The audited defect was a GREEN verification over a broken state. Step 5 checked
  # the member list and the threshold, and a permission mask is neither — so a
  # member who cannot Execute read as a completed rotation, and the truth arrived
  # weeks later as a failed upgrade.
  #
  # This grades the SOP's ASSERTIONS, not its RPC call: `squads_members` is stubbed
  # with a canned account read and nothing here touches mainnet. The reader is not
  # the part that can be wrong. Whether a wrong mask FAILS is, and a check that
  # cannot fail is the defect itself.
  test "step 5's Squads check fails on a wrong permission mask, and passes on the right one" do
    block = blocks_under("#### Verifying the Squads rotation")
            .find { |b| b[:body].include?("check_squads_rotation()") }

    refute_nil block,
               "the SOP no longer defines `check_squads_rotation()` under its Squads verification " \
               "heading. Step 5 is then back to eyeballing a member list, which passes over a member " \
               "holding a mask that cannot run `squad-upgrade.js`."

    stub = lambda do |lines|
      "squads_members() { printf '%s\\n' " + lines.map { |l| "'#{l}'" }.join(" ") + "; }\n"
    end

    healthy = ["threshold 2", "#{NEW_MEMBER} 7", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"]

    Dir.mktmpdir("crs-squads") do |dir|
      # ── the control: a correct rotation must PASS ─────────────────────────
      ok = run_block(stub.call(healthy) + block[:body], dir, {})

      assert_equal 0, ok[:status],
                   "the Squads check REJECTED a CORRECT rotation (3 members, threshold 2, new key at " \
                   "mask 7, old key gone). Every refusal below then proves only that the check is " \
                   "broken.\nstdout: #{ok[:out]}\nstderr: #{ok[:err]}"
      assert_includes ok[:out], "PASS",
                      "a passing check printed no PASS line: #{ok[:out].inspect}. Silence and success " \
                      "look identical to an operator working down a runbook."

      # ── the states it exists to catch ─────────────────────────────────────
      # The three partial masks are each a REAL call site in squad-upgrade.js
      # losing its bit — they are the whole reason the mask is checked at all.
      {
        "mask 3 — Initiate|Vote, no Execute (vaultTransactionExecute :172 breaks)" =>
          ["threshold 2", "#{NEW_MEMBER} 3", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"],
        "mask 5 — Initiate|Execute, no Vote (proposalApprove :161 breaks)" =>
          ["threshold 2", "#{NEW_MEMBER} 5", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"],
        "mask 6 — Vote|Execute, no Initiate (vaultTransactionCreate :155 breaks)" =>
          ["threshold 2", "#{NEW_MEMBER} 6", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"],
        "the rotated-out key is STILL a member" =>
          ["threshold 2", "#{NEW_MEMBER} 7", "#{OLD_MEMBER} 7", "#{KEEP_MEMBER_A} 7"],
        "the new key never landed" =>
          ["threshold 2", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"],
        "threshold moved off 2" =>
          ["threshold 3", "#{NEW_MEMBER} 7", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"],
        "the multisig is down to a 2-of-2" =>
          ["threshold 2", "#{NEW_MEMBER} 7", "#{KEEP_MEMBER_A} 7"]
      }.each do |label, lines|
        result = run_block(stub.call(lines) + block[:body], dir, {})

        refute_equal 0, result[:status],
                     "the Squads check PASSED on a broken rotation (#{label}). That is the audited " \
                     "defect verbatim — a green step 5 over a multisig that cannot run " \
                     "squad-upgrade.js.\nstdout: #{result[:out]}"
        assert_includes result[:out] + result[:err], "FAIL",
                        "the check exited non-zero on #{label} but printed no FAIL line, so the operator " \
                        "sees a failure with no reason: #{result[:out].inspect}"
      end

      # The mask failure must NAME the mask it found. "Wrong permissions" sends the
      # operator back to app.squads.so with nothing to compare against.
      wrong = run_block(
        stub.call(["threshold 2", "#{NEW_MEMBER} 3", "#{KEEP_MEMBER_A} 7", "#{KEEP_MEMBER_B} 7"]) + block[:body],
        dir, {}
      )

      assert_includes wrong[:out], "mask is 3",
                      "the mask failure does not report the mask it actually found: #{wrong[:out].inspect}"
    end
  end

  # Structural, not prose-matching: `addMember` takes a `Member { key, permissions }`,
  # so every one the SOP writes must carry a mask. A bare `addMember(<new pubkey>)`
  # is the instruction that shipped, and it leaves the choice to whatever the Squads
  # UI had checked.
  test "every addMember the SOP writes carries a permission mask" do
    calls = SOP.read.scan(/addMember\([^)]*\)/)

    assert_operator calls.length, :>=, 2,
                    "only #{calls.length} addMember call(s) found in the SOP — it names the Squads " \
                    "rotation in both the mechanism paragraph and the ordered step 4, so this scan has " \
                    "gone blind and would pass on nothing."

    bare = calls.reject { |c| c.include?("Permissions.all") }

    assert_empty bare,
                 "these addMember calls name no permission mask: #{bare.inspect}. The operator then " \
                 "accepts whatever app.squads.so had checked, and `squad-upgrade.js` needs all three " \
                 "bits (Initiate :155, Vote :161, Execute :172). Write Permissions.all()."
  end

  # ── Finding E: the coverage claim, made self-enforcing ────────────────────
  #
  # 4.2 was not a MISSING guard — its `${NEW:?…} &&` chain shipped correct. It was a
  # false COVERAGE claim: no test executed 4.2, so un-chaining it left the suite
  # green while zap 5b292c36's commit message said "un-chaining any guard turns it
  # red". A protection believed to exist is worse than one known to be absent.
  #
  # Adding 4.2 to WRITE_LANES makes that sentence true today. This keeps it true:
  # a new mutating block under a new heading, or a lane deleted from WRITE_LANES,
  # both land here instead of passing silently.
  test "every bash block that mutates a store sits under a graded WRITE lane" do
    mutating = bash_blocks.select { |b| b[:body] =~ MUTATING }

    assert_operator mutating.length, :>=, 4,
                    "only #{mutating.length} mutating bash blocks found in the SOP, expected at least 4 " \
                    "(the 1Password edit, the Heroku write, the desk `.env` rewrite, the snapshot sweep). " \
                    "The MUTATING pattern has gone blind and this assertion would pass on nothing."

    ungraded = mutating.map { |b| b[:heading] }.uniq - WRITE_LANES.keys

    assert_empty ungraded,
                 "these headings contain shell that MUTATES a store, but no behavioural lane executes " \
                 "them: #{ungraded.inspect}. Their guards are unverified — un-chaining one would leave " \
                 "this suite green, which is exactly the gap 4.2 sat in until 2026-09-09. Add the heading " \
                 "to WRITE_LANES with the substring that selects its writing blocks."
  end
end
