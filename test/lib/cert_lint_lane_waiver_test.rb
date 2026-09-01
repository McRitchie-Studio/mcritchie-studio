require "test_helper"
require "ripper"
require Rails.root.join("bin/lib/full_suite_gate").to_s
require Rails.root.join("bin/lib/lint_waiver_guard").to_s

# A REPO MAY DECLARE THAT IT HAS NO LINT LANE. It may never be INFERRED to.
#
# studio-engine ships no rubocop — not in the Gemfile, not in the gemspec, no
# .rubocop.yml, and `bundle exec rubocop` fails outright. Its static gate is
# `ruby -c` inside bin/release-check. Before this, the cert gate demanded a
# rubocop cert per named repo, so a task naming the engine could NEVER be
# certified: the only way through was pointing FULL_SUITE_RUBOCOP_CMD at a no-op,
# which records a rubocop pass for a lint that never ran. That was refused on
# 2026-08-24 and the task was scoped down instead; this is the honest fix.
#
# THE DISTINCTION THIS FILE DEFENDS is declared-vs-inferred. Waiving the lane
# because no rubocop BINARY is present would turn every broken rubocop install
# into a silently skipped lane — the self-declaration disease config/e2e_lane.yml
# exists to prevent. The waiver must be a reviewable line in a registry.
class CertLintLaneWaiverTest < ActiveSupport::TestCase
  TEST = FullSuiteGate::TEST_LANE
  RUBOCOP = FullSuiteGate::RUBOCOP_LANE

  GATE_PATH = Rails.root.join("bin/lib/full_suite_gate.rb")
  GUARD_PATH = Rails.root.join("bin/lib/lint_waiver_guard.rb")

  # The ORIGINAL scan, preserved VERBATIM and still run against the RAW source, so
  # nothing this file used to refuse is now allowed. The widened scan below is
  # added on top of it, never in place of it.
  BINARY_PROBE = /which\s+rubocop|rubocop\s+--version|File\.exist\?\(.*rubocop/

  # LINT-TOOLCHAIN PROBING — the thing full_suite_gate.rb must never do. Shelling
  # out for the binary; reading a rubocop config or binstub; reading a Gemfile or
  # gemspec (the files that record whether this repo ASKED to be linted); or
  # globbing the tree for any of them. Run against COMMENT-STRIPPED source only —
  # see the long note on the registry test for why that is required rather than
  # convenient.
  TOOLCHAIN_PROBE = Regexp.union(
    /which\s+rubocop/,
    /rubocop\s+--version/,
    /bundle\s+exec\s+rubocop/,
    /\.rubocop\.ya?ml/,
    %r{bin/rubocop},
    /Gemfile/,
    /gemspec/,
    /Dir\.glob/,
    /File\.(?:exist\?|file\?|read|readlines|directory\?)\s*\([^\n)]*rubocop/
  ).freeze

  test "a repo that declares no lint lane owes only the suite" do
    %w[studio-engine solana-studio].each do |repo|
      assert_equal [TEST], FullSuiteGate.required_lanes(repo),
                   "#{repo} declares lint_lane: none, so a rubocop cert is not owed"
    end
  end

  test "every other repo still owes BOTH lanes" do
    %w[mcritchie-studio turf-monster].each do |repo|
      assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(repo),
                   "#{repo} has not declared a waiver and must still owe a rubocop cert"
    end
  end

  # bin/fast-check carries NO lint-waiver branch, and says so in a comment whose
  # reasoning is "every declaring repo is a gem, and the gem branch above already
  # omitted the lane". That is only true while it is true. Asserting it here means a
  # NON-gem repo declaring the waiver reddens this test instead of silently turning
  # that paragraph into a lie and leaving fast-check running `bin/rubocop` against a
  # repo the registry says has none.
  test "every repo declaring the waiver is a gem, which is what lets fast-check skip the branch" do
    registry = YAML.safe_load_file(Rails.root.join("config/release_repos.yml"))
    declaring = %w[gems apps].flat_map do |section|
      (registry[section] || {}).select { |_, row| row.is_a?(Hash) && row["lint_lane"].to_s == "none" }
                               .keys.map { |slug| [section, slug] }
    end

    assert declaring.any?, "the waiver must still be declared by someone, or every test here is vacuous"
    assert_equal [], declaring.reject { |section, _| section == "gems" },
                 "a NON-gem repo now declares lint_lane: none — bin/fast-check's gem branch no longer " \
                 "covers it, so give that script the waiver branch its comment defers"
  end

  # FAIL CLOSED. A gate that waives a lane for an input it does not recognise is
  # worse than one that never waives: a typo'd slug would silently drop a lane.
  test "an unknown repo, a blank one, and nil all owe EVERYTHING" do
    [nil, "", "   ", "not-a-repo", "studio_engine"].each do |repo|
      assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(repo),
                   "#{repo.inspect} must not waive a lane — only a declared repo may"
    end
  end

  # The declaration is the ONLY thing that waives. This is the anti-inference
  # guard: if someone later makes the gate probe for a rubocop binary, the
  # registry stops being the source of truth and this test should be the thing
  # that objects.
  # UNCHANGED AND UNLOOSENED by the audit added on 2026-08-31. The audit
  # (bin/lib/lint_waiver_guard.rb) does read the tree, but it can only REVOKE a
  # waiver, never grant one — so it deliberately lives in its OWN file and this
  # assertion still bites on the module that DECIDES the waiver.
  # The revoke-only direction is asserted in test/lib/lint_waiver_guard_test.rb.
  #
  # WHAT THIS SCAN ENFORCES, at the strength it can actually keep. It refuses
  # LINT-TOOLCHAIN PROBING in full_suite_gate.rb: shelling out for the binary,
  # reading a rubocop config or binstub, reading a Gemfile or gemspec, or globbing
  # the tree for any of them.
  #
  # IT DOES NOT REFUSE "ANY ENVIRONMENT READ", and it must not. This comment
  # claimed that until 2026-08-31 (/tasks/claims-overstate-their-mechanism), and
  # the claim was false in both directions. The regex never implemented it — and
  # it could not: full_suite_gate.rb reads the environment constantly BY DESIGN.
  # It shells out to git for the fingerprint, writes a throwaway index under
  # Dir.tmpdir, and YAML-loads config/release_repos.yml — that last one being the
  # registry read that MAKES the waiver a declaration. A guard that refused every
  # environment read would refuse the file as it stands.
  #
  # MEASURED, and why the scan was widened. The old regex was
  # `which rubocop|rubocop --version|File.exist?(.*rubocop`, and on 2026-08-31 it
  # was run against LintWaiverGuard#markers pasted into full_suite_gate.rb — the
  # most likely way this invariant would actually break. It MISSED, because the
  # guard's own idiom is `File.file?` with the path held in a constant, so
  # "rubocop" never appears on the same line as the read. That paste is now a
  # standing mutation test below, so the comment and the scan cannot drift apart
  # again without something going red.
  #
  # AND IT SCANS THE CODE, NOT THE PROSE. Comments are stripped first, because
  # full_suite_gate.rb's own header contains "no .rubocop.yml", "bin/rubocop",
  # "the Gemfile", "the gemspec" and "bundle exec rubocop" — five probe patterns,
  # all of them in sentences EXPLAINING the rule. Scanning raw source would redden
  # on the explanation. The stripper is Ripper, not a regex, so a "#" inside a
  # string or an interpolation cannot be mistaken for a comment; the test below
  # proves the stripped source still contains the gate's real code.
  test "the waiver comes from the registry, not from probing the tree for a lint toolchain" do
    registry = Rails.root.join("config/release_repos.yml")
    gems = YAML.safe_load_file(registry).fetch("gems")

    %w[studio-engine solana-studio].each do |repo|
      assert_equal "none", gems.fetch(repo)["lint_lane"],
                   "#{repo}'s waiver must be a reviewable line in config/release_repos.yml"
    end

    source = GATE_PATH.read
    assert_no_match(BINARY_PROBE, source,
                    "the gate must NOT probe for a rubocop binary — a waiver inferred from a " \
                    "missing install turns every broken rubocop into a silently skipped lane")

    hits = code_without_comments(source).scan(TOOLCHAIN_PROBE).uniq
    assert_equal [], hits,
                 "full_suite_gate.rb now reads the tree for a lint toolchain (#{hits.join(', ')}). " \
                 "The module that DECIDES the waiver must decide it from config/release_repos.yml " \
                 "alone. If this read belongs anywhere it is bin/lib/lint_waiver_guard.rb, which may " \
                 "only REVOKE a waiver and never grant one — that separation is the whole design."
  end

  # PROVE THE INPUT. The scan above reads about a third of the file's bytes, and a
  # stripper that ate too much would make it pass by reading nothing — a green test
  # that checks an empty string. So assert both halves of the strip: the gate's real
  # code survives, and its prose does not.
  test "the comment strip leaves the gate's code standing and drops only its prose" do
    raw = GATE_PATH.read
    code = code_without_comments(raw)

    refute_empty code, "the comment strip returned nothing — the scan above would be vacuous"
    ["def lint_waived?", "IO.popen", "YAML.safe_load_file", "File.exist?"].each do |kept|
      assert code.include?(kept), "the strip removed real code (#{kept}), so it removes too much"
    end

    # These five are the reason the scan is comment-stripped rather than raw: each
    # is a TOOLCHAIN_PROBE pattern that appears in the gate's own explanation of
    # why it must not probe. If any ever moves into code, the registry test reddens.
    # Asserted on a BOOLEAN rather than with assert_includes so a failure prints
    # this sentence instead of 7KB of stripped source.
    ["bundle exec rubocop", "bin/rubocop", ".rubocop.yml", "Gemfile", "gemspec"].each do |prose|
      assert raw.include?(prose), "expected the gate's prose to still discuss #{prose}"
      assert_not code.include?(prose),
                 "#{prose} is now in full_suite_gate.rb's CODE, not just its comments — " \
                 "the registry test above should be red too, and it is the one to read"
    end
  end

  # THE MUTATION. The question the registry test's comment makes a claim about is
  # "would this catch the real thing?", and the real thing has a name: moving
  # LintWaiverGuard#markers — the tree read that decides whether a waived repo has
  # quietly gained a lint toolchain — into the module that DECIDES the waiver.
  # Splice it in and the scan must go red. Nothing here trusts a recorded result:
  # the splice is applied to the live file's text and re-scanned every run.
  test "pasting LintWaiverGuard#markers into the gate reddens the scan" do
    markers = method_source(GUARD_PATH.read, "markers")

    # The slice must be the real method, or the mutation proves nothing about it.
    assert markers.start_with?("  def markers(root)"), "sliced the wrong method: #{markers[0, 60].inspect}"
    assert markers.end_with?("  end\n"), "the slice did not end at the method's own `end`"
    ["File.file?", "Dir.glob", "CONFIG_FILES", "BINSTUB"].each do |token|
      assert_includes markers, token, "the slice is missing #{token} — it is not LintWaiverGuard#markers"
    end

    gate = GATE_PATH.read
    mutated = gate.sub(/^  module_function\n/) { |anchor| "#{anchor}\n#{markers}" }
    refute_equal gate, mutated, "the splice did not apply — this test would prove nothing"
    assert code_without_comments(mutated).include?("def markers"),
           "the spliced method did not survive the comment strip"

    hits = code_without_comments(mutated).scan(TOOLCHAIN_PROBE).uniq
    refute_empty hits,
                 "LintWaiverGuard#markers pasted into full_suite_gate.rb did NOT redden the scan. " \
                 "That is exactly the hole this test exists to close: the gate would be reading the " \
                 "tree for .rubocop.yml, bin/rubocop, the Gemfile and every gemspec, and the guard " \
                 "would say nothing. Widen TOOLCHAIN_PROBE until this bites again."
  end

  # KEEP THE VOCABULARIES IN SYNC. TOOLCHAIN_PROBE is a hand-written list, and
  # LintWaiverGuard's marker set is the authority on what "this repo lints" looks
  # like. Add a marker there without adding it here and the scan silently goes thin
  # — the drift this whole file was rewritten to stop.
  test "every lint-toolchain marker LintWaiverGuard recognises is one the scan refuses" do
    markers = LintWaiverGuard::CONFIG_FILES + [LintWaiverGuard::BINSTUB]

    refute_empty markers, "no markers to check — the parity assertion would be vacuous"
    markers.each do |marker|
      assert_match TOOLCHAIN_PROBE, marker,
                   "LintWaiverGuard treats #{marker} as proof a repo lints, but TOOLCHAIN_PROBE " \
                   "would not notice full_suite_gate.rb reading it. Add it to the union."
    end
  end

  # Guard the guard: LANES must actually contain the rubocop lane, or every
  # assertion above is comparing two identical lists and proves nothing.
  test "the rubocop lane is genuinely one of the full-cert lanes" do
    assert_includes FullSuiteGate::LANES, RUBOCOP
    assert_includes FullSuiteGate::LANES, TEST
  end

  # Ruby source with every comment token dropped, using Ruby's own lexer. A regex
  # stripper would have to guess whether a "#" opens a comment, opens an
  # interpolation, or sits inside a string or a regex; Ripper already knows, and
  # the file this scans contains all four.
  def code_without_comments(source)
    Ripper.lex(source)
          .reject { |(_, type, _)| type == :on_comment }
          .map { |(_, _, token)| token }
          .join
  end

  # The text of a module-level `def <name>` through its own `end`. Nested blocks
  # close at a deeper indent, so the first `  end` at the method's own level is the
  # method's. Raises rather than returning a partial slice: a mutation built from
  # the wrong lines still goes red or green and tells you nothing about the method
  # you meant to move.
  def method_source(source, name)
    lines = source.lines
    start = lines.index { |line| line.match?(/\A  def #{Regexp.escape(name)}\b/) }
    raise "no module-level `def #{name}` in the source given" unless start

    length = lines[start..].index { |line| line == "  end\n" }
    raise "`def #{name}` is never closed by an `end` at its own indent" unless length

    lines[start, length + 1].join
  end
end
