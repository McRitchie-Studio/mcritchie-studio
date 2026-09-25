# frozen_string_literal: true

require "test_helper"

# THE ORPHAN PROPERTY, GENERALIZED PAST ONE FILENAME (generalize-credential-shell-guard).
#
# `credential_rotation_shell_guard_test.rb` pins SOP to ONE file, so its B1 assertion
# — nothing is EXPANDED that the SOP never ASSIGNS — could only ever see
# credential-rotation.md. The defect it describes then shipped in a different SOP:
# workspace-provision.md interpolated `$KEYFILE` into a `heroku config:set` having
# assigned it nowhere, writing an empty string to a production config var while every
# command exited 0. It was fixed by hand (commit ec8a814b) and nothing has stopped it
# coming back, because no guard reads that file.
#
# THIS FILE DOES NOT REPLACE B1. B1 keeps the assertions that are ABOUT
# credential-rotation — that `$NEW` specifically is expanded and assigned — plus a
# behavioural sandbox that only makes sense for that SOP's phases. This is the wider,
# shallower net: the same static property, over every SOP in the tree.
#
# THE POPULATION IS DERIVED, NOT ENUMERATED. A hard-coded list of "credential
# SOPs" is the fix that covers the file we already know about and misses the one
# written tomorrow — the same hole test/support/stated_prose.rb was written to close.
# Every soul's SOP directory is in scope, because a credential reaches a shell in
# whichever SOP happens to handle one.
#
# WIDENING FORCED THREE CORRECTIONS, each of them shell SEMANTICS rather than a
# heuristic tuned until the suite went green. Measured 2026-09-22 across 27 SOPs:
#
#   1. A QUOTED heredoc body (`<<'EOF'`) is LITERAL — the shell expands nothing in
#      it. sleeper-auction-watch.md writes two Node programs that way, and their
#      JavaScript template literals (`${TEAMS}`, `${Math.max(...)}`) read as 15
#      shell expansions that do not exist. An UNQUOTED `<<EOF` does expand and is
#      kept.
#   2. SINGLE QUOTES are literal for the same reason. share-insights.md runs
#      `ruby -e '...$stdin.read...'`; `$stdin` is Ruby's global, not a shell
#      variable the SOP forgot to set.
#   3. Only FENCED blocks are graded. B1 also reads inline `code spans`, which is
#      right for credential-rotation.md where they are runnable one-liners. Across
#      a wide population they are mostly ILLUSTRATIONS, including deliberate
#      anti-patterns a SOP is warning against — content-build.md names `work=…` to
#      show the trap, production-deploy.md names `${VAR:-absent}` to forbid it.
#      Grading prose would red four SOPs for teaching correctly. A fenced block is
#      what a reader copies, and it is where the KEYFILE defect lived.
#
# A variable whose every expansion carries a `:-` / `:=` fallback is also exempt: it
# cannot interpolate empty. The rule is EVERY site, not any — one bare `$X` beside a
# guarded `${X:-d}` is still lethal, and still reported.
class CredentialShellOrphanGuardTest < ActiveSupport::TestCase
  SOP_GLOB = "docs/agents/agents/*/sops/*.md"

  # Names a SOP may expand without assigning, each with the reason it arrives from
  # outside the file. Anything else must be assigned by the SOP itself.
  EXTERNALLY_PROVIDED = {
    "HOME"   => "set by the OS for every login shell",
    "EDITOR" => "the operator's own editor preference, set in his shell profile",
    # NOTE: no TMPDIR here, though B1 allows it. B1 also grades inline `code spans`,
    # and TMPDIR is expanded only in credential-rotation.md's prose — never in a
    # fenced block. Listing it here would be an allowance covering nothing, which the
    # staleness assertion below correctly refuses.
    "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" =>
      "1Password service-account token, exported into the session by the launcher " \
      "rather than assigned in any SOP — a SOP that assigned one would be printing it",
    "OP_APPLICATIONS_SERVICE_ACCOUNT_TOKEN" => "1Password service-account token, exported by the launcher",
    "OP_INDUSTRIES_SERVICE_ACCOUNT_TOKEN"   => "1Password service-account token, exported by the launcher"
  }.freeze

  # A SOP with a REAL orphan that this guard cannot fix from here, because the remedy
  # is a prose change to that SOP and it carries its own card.
  #
  # THIS IS NOT AN ALLOWLIST. Each entry is asserted to still be true below, so the day
  # the card lands this test FAILS and the file must move into the covered set. An
  # exemption nobody re-measures is how a guard goes quiet.
  #
  # It is EMPTY today: credential-filing.md's $VALUE orphan was the only entry, and
  # guard-credential-filing-value fixed it, so the file is now graded with every other
  # SOP. The staleness test below keeps asserting on the empty case rather than going
  # quiet — see the comment there.
  KNOWN_UNGUARDED = {}.freeze

  # ── extraction ──────────────────────────────────────────────────────────────

  def sops
    @sops ||= Dir.glob(Rails.root.join(SOP_GLOB)).sort
  end

  def rel(path)
    Pathname.new(path).relative_path_from(Rails.root.join("docs/agents/agents")).to_s
  end

  # Every fenced ```bash block's body, heredocs and single quotes already neutralised.
  def fenced_shell(text)
    blocks = []
    buf = nil
    text.each_line do |line|
      if buf
        line.strip.start_with?("```") ? (blocks << buf.join; buf = nil) : buf << line
      elsif line.strip.start_with?("```bash")
        buf = []
      end
    end
    strip_single_quoted(blocks.map { |b| strip_quoted_heredocs(b) }.join("\n"))
  end

  # A quoted delimiter means the body is literal. An unquoted one expands, so it stays.
  def strip_quoted_heredocs(body)
    out = []
    delim = nil
    body.each_line do |line|
      if delim
        delim = nil if line.strip == delim
        next
      end
      if (m = line.match(/<<-?\s*(['"])([A-Za-z_][A-Za-z0-9_]*)\1/))
        delim = m[2]
        out << line.sub(/<<-?\s*(['"])[A-Za-z_][A-Za-z0-9_]*\1.*/, "")
      else
        out << line
      end
    end
    out.join
  end

  def strip_single_quoted(text)
    text.gsub(/'[^'\n]*'/, "''")
  end

  # Each expansion SITE as [name, carried_a_default].
  def expansion_sites(text)
    text.scan(/\$(\{)?([A-Za-z_][A-Za-z0-9_]*)(:[-=][^}]*)?(\})?/)
        .map { |brace, name, default, _| [name, !brace.nil? && !default.nil?] }
  end

  def assigned_variables(text)
    names = []
    names += text.scan(/(?:\A|[\n;&|(]|\bexport\s+|\blocal\s+)[ \t]*([A-Za-z_][A-Za-z0-9_]*)=/).flatten
    names += text.scan(/\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b/).flatten
    names += text.scan(/\blocal\s+([A-Za-z_][A-Za-z0-9_]*)\b/).flatten
    # A `read` assigns EVERY name it lists. Capturing only the first reports the rest
    # as orphans — measured on bucket-provision.md, whose `read -r PROD_ID PROD_SECRET`
    # made two correctly-assigned credentials look unassigned.
    text.scan(/(?:\A|[\n;&|(])[ \t]*read\s+((?:-\S+[ \t]+)*)([A-Za-z_][A-Za-z0-9_ \t]*)/) do
      names += Regexp.last_match(2).split(/[ \t]+/)
    end
    names.uniq
  end

  def orphans_in(path)
    shell = fenced_shell(File.read(path))
    sites = expansion_sites(shell)
    expanded = sites.map(&:first).uniq
    always_defaulted = expanded.select { |n| sites.select { |s, _| s == n }.all? { |_, d| d } }
    expanded - assigned_variables(shell) - always_defaulted - EXTERNALLY_PROVIDED.keys
  end

  # ── the population ──────────────────────────────────────────────────────────

  test "[unit] the population is DERIVED from the SOP tree, not a list of known files" do
    assert_operator sops.length, :>=, 20,
                    "only #{sops.length} SOPs globbed out of #{SOP_GLOB} — the glob has gone blind and " \
                    "every assertion below would grade an empty corpus"

    souls = sops.map { |p| rel(p).split("/").first }.uniq
    assert_operator souls.length, :>=, 4,
                    "the population reaches only #{souls.inspect} — a guard that reads one soul's " \
                    "directory is the pinned-filename bug at a coarser grain"

    assert_includes sops.map { |p| rel(p) }, "steffon/sops/workspace-provision.md",
                    "the SOP the motivating defect shipped in is not in the population"
  end

  test "[unit] the corpus actually parses as shell — blocks, expansions and assignments" do
    graded = sops.reject { |p| fenced_shell(File.read(p)).empty? }

    assert_operator graded.length, :>=, 15,
                    "only #{graded.length} SOPs yielded any fenced bash — the fence scanner has gone blind"

    expansions = sops.sum { |p| expansion_sites(fenced_shell(File.read(p))).length }
    assert_operator expansions, :>=, 40,
                    "only #{expansions} expansion sites across the whole corpus — the expansion regex " \
                    "has stopped matching and the orphan assertion would pass on nothing"

    assignments = sops.sum { |p| assigned_variables(fenced_shell(File.read(p))).length }
    assert_operator assignments, :>=, 30,
                    "only #{assignments} assignments across the corpus — the assignment regex has gone " \
                    "blind, which would report every variable in the tree as an orphan"
  end

  # The motivating case, pinned as a positive control: this exact pair is what the
  # guard exists to keep true, and a guard that cannot see it is decoration.
  test "[unit] the motivating SOP still both expands and assigns its key variable" do
    shell = fenced_shell(Rails.root.join("docs/agents/agents/steffon/sops/workspace-provision.md").read)

    assert_includes expansion_sites(shell).map(&:first), "KEYFILE",
                    "workspace-provision.md stopped expanding $KEYFILE — re-point this control at " \
                    "whatever variable now carries the service-account key path"
    assert_includes assigned_variables(shell), "KEYFILE",
                    "workspace-provision.md expands $KEYFILE but no longer assigns it. This is the " \
                    "defect the file was fixed for: `heroku config:set` then writes an empty string " \
                    "to a production config var and exits 0."
  end

  # ── the property ────────────────────────────────────────────────────────────

  test "[unit] no SOP expands a shell variable it never assigns" do
    offenders = sops.each_with_object({}) do |path, acc|
      known = KNOWN_UNGUARDED.dig(rel(path), :orphans) || []
      found = orphans_in(path) - known
      acc[rel(path)] = found if found.any?
    end

    assert_empty offenders,
                 "these SOPs EXPAND shell variables in a fenced block that they never ASSIGN: " \
                 "#{offenders.inspect}. Each interpolates the empty string for a reader who copies " \
                 "the block — which is how a provisioning SOP wrote an empty service-account key to a " \
                 "production config var while every command exited 0. Assign it in the step that " \
                 "introduces it, guard it with a non-empty refusal, or add it to EXTERNALLY_PROVIDED " \
                 "with the reason it comes from outside."
  end

  test "[unit] every EXTERNALLY_PROVIDED name is still expanded by some SOP" do
    expanded = sops.flat_map { |p| expansion_sites(fenced_shell(File.read(p))).map(&:first) }.uniq
    stale = EXTERNALLY_PROVIDED.keys - expanded

    assert_empty stale,
                 "EXTERNALLY_PROVIDED names variables no SOP uses any more: #{stale.inspect}. Remove " \
                 "them — an allowance nobody is reviewing quietly widens what this guard permits."
  end

  # The exemption measures its own condition. When the card fixes the file, this fails.
  test "[unit] every KNOWN_UNGUARDED entry still has the orphan it was excused for" do
    KNOWN_UNGUARDED.each do |relative, entry|
      path = Rails.root.join("docs/agents/agents", relative)
      assert path.exist?, "KNOWN_UNGUARDED names #{relative}, which no longer exists"

      still = orphans_in(path.to_s)
      entry[:orphans].each do |name|
        assert_includes still, name,
                        "#{relative} no longer orphans $#{name} — the exemption has outlived its " \
                        "reason. Task #{entry[:card]} fixed it: delete this KNOWN_UNGUARDED entry so " \
                        "the file is graded with every other SOP."
      end
    end

    # An EMPTY hash walks that loop ZERO times. Without the assertion below this test then
    # proves nothing while reporting green, and minitest says so out loud ("Test is missing
    # assertions") in a line nobody reads. Empty is itself a claim — that no SOP needs
    # excusing — so assert THAT. This keeps the test biting on the case it is really for:
    # a hash emptied to SILENCE a failure rather than to RECORD a fix.
    return unless KNOWN_UNGUARDED.empty?

    dirty = sops.select { |p| orphans_in(p).any? }.map { |p| rel(p) }
    assert_empty dirty,
                 "KNOWN_UNGUARDED is empty, which asserts that every SOP is clean, but " \
                 "#{dirty.inspect} still expand a shell variable they never assign. Emptying this " \
                 "hash is how a FIX is recorded, not how a FAILURE is silenced: restore the entry " \
                 "with the card that will fix it, or fix the file."
  end
end
