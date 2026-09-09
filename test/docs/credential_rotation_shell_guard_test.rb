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
    heroku = File.join(bin, "heroku")
    File.write(heroku, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"#{File.join(dir, 'heroku.log')}\"\n")
    FileUtils.chmod(0o755, heroku)

    dir
  end

  def desk_envs(dir)
    Dir.glob(File.join(dir, "*", ".worktrees", "*", ".env"))
  end

  # Rewrites the SOP's real paths and its <VAR> placeholder onto the sandbox, then
  # REFUSES to run anything still pointing at the real projects root.
  def run_block(body, dir, env)
    script = body.gsub(PROJECTS_ROOT, dir).gsub("<VAR>", FIXTURE_VAR)

    refute_includes script, PROJECTS_ROOT,
                    "REFUSING TO EXECUTE: after path rewriting this snippet still references #{PROJECTS_ROOT}. " \
                    "Running it would rewrite real `.env` files and delete real env snapshots. Fix the " \
                    "rewrite in this test before touching anything else."

    full_env = { "PATH" => "#{File.join(dir, 'bin')}:#{ENV['PATH']}" }.merge(env)
    stdout, stderr, status = Open3.capture3(full_env, "bash", "-c", script, unsetenv_others: false, chdir: dir)
    { out: stdout, err: stderr, status: status.exitstatus, script: script }
  end

  def heroku_calls(dir)
    path = File.join(dir, "heroku.log")
    File.exist?(path) ? File.readlines(path).map(&:chomp) : []
  end

  # ── B1, behaviourally: the writes refuse, and the control proves they can write

  test "Phase 4.4's writes REFUSE to run with $NEW unset, and still write when it is set" do
    blocks = blocks_under("### 4.4 Write the runtime stores")
    writing = blocks.select { |b| b[:body].include?("$NEW") }

    assert_operator writing.length, :>=, 2,
                    "only #{writing.length} of Phase 4.4's #{blocks.length} bash blocks interpolate $NEW. " \
                    "The Heroku write and the desk `.env` rewrite are both supposed to — if one stopped, " \
                    "either it was removed or it now writes the value some other way this guard cannot see."

    # ── the refusal ────────────────────────────────────────────────────────
    Dir.mktmpdir("crs-refuse") do |dir|
      build_sandbox(dir)
      env = { "APPS" => "fixture-app-one fixture-app-two", "ROTATED_AT" => "2026-09-09T12:00:00Z" }

      writing.each do |block|
        result = run_block(block[:body], dir, env)

        refute_equal 0, result[:status],
                     "a Phase 4.4 block that interpolates $NEW ran to SUCCESS with $NEW unset. It wrote " \
                     "the empty string into a real store and reported nothing wrong. Open the block with " \
                     ": \"${NEW:?...}\" so it refuses.\n--- script ---\n#{result[:script]}"
      end

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

      writing.each { |block| run_block(block[:body], dir, env) }

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
end
