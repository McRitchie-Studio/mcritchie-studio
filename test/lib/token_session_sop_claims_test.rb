# frozen_string_literal: true

# [unit] What the REGISTERED SOPs are allowed to say about who fixes a credential
# refusal. Sibling of test/lib/credential_isolation_claims_test.rb, which pins the
# vault claims the same way.
#
# ---------------------------------------------------------------------------
# THE DEFECT (2026-08-30, measured — it cost most of a session and blocked a
# production deploy on Mr. McRitchie for hours).
#
# `bin/gh-token` and `bin/gh-app-git-credential` were fixed to print
# `source ~/.zprofile.admin` for a deployer refusal on a provisioned machine.
# docs/agents/modules/token-session.md was not. It is a REGISTERED SOP
# (docs/agents/index.md), and the Claude adapter routes agents to it BY NAME when
# a credential failure does not clear — so an agent following the operating model
# CORRECTLY (read the mapped SOP before probing the tool) reached the WRONG
# conclusion FASTER than one who just ran the command. Three spots said the
# deployer case was the operator's, contradicting source-control.md and both
# messages the shipped tool prints.
#
# WHY THIS IS NOT COSMETIC. An agent who cannot act on a refusal ROUTES AROUND it,
# and the documented routes around are `--builder none` (which lifts the
# no-self-review guard entirely) and "escalate to Mr. McRitchie" — the terminal
# chore AGENTS.md forbids.
# ---------------------------------------------------------------------------
#
# WHY A PROPERTY SCAN RATHER THAN A LIST OF DELETED SENTENCES. A test that greps
# for the exact removed strings passes the moment somebody re-words the same false
# claim, which is the likeliest way it comes back. These assert the RULE the prose
# has to follow, and the agreement between the docs and the tool.

require "bundler/setup"
require "minitest/autorun"
require_relative "../../bin/lib/op_vaults"

class TokenSessionSopClaimsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  SOP        = "docs/agents/modules/token-session.md"
  DEEPER_REF = "docs/agents/modules/source-control.md"

  SELF_SERVICE = "source ~/.zprofile.admin"
  INSTALL      = "bin/setup-1pass-token --admin"

  # Language that hands the job to the operator.
  # NOTE the `escalat(e|ion)` alternation. Written as bare /escalate/ this missed
  # the original defect's own heading, "The one honest escalation" — the exact
  # string it was written to catch. Caught by mutation, not by review.
  # ROUTING language, not every mention of his name. A bare /Mr\. McRitchie/ also
  # matched "two merges landed under Mr. McRitchie's own account" — narrative, in a
  # section about a different trap entirely. A rule that flags prose nobody would
  # act on gets deleted by the next person, taking the real guard with it.
  ESCALATION = /escalat(?:e|ion|ing)|needs? Mr\. McRitchie|Mr\. McRitchie (?:must|has to|needs? to)|
                needs? .{0,25}to supply|ask (?:him|the operator|Mr\. McRitchie)/xi

  def read(rel) = File.read(File.join(ROOT, rel))

  # ── 1. THE SOP MUST NAME THE COMMAND THE TOOL NAMES ─────────────────────────
  #
  # The doc and the binary must not disagree about who owns the failure. This is
  # the exact contradiction that cost the session: the tool said "source it", the
  # registered SOP said "escalate", and the SOP is what gets read first.
  def test_the_sop_names_the_same_remedy_the_tool_prints
    remedy = with_provisioned(true) { OpVaults.diagnose(:deployer) }

    assert_includes remedy, SELF_SERVICE, "guard the guard: the tool must still print it"
    assert_includes read(SOP), SELF_SERVICE,
                    "#{SOP} is a REGISTERED SOP and is read BEFORE the tool is run. " \
                    "If it does not name the command the tool names, the agent who " \
                    "follows the operating model correctly is the one who gets it wrong."
  end

  # ── 2. THE PROVISIONED CASE IS NOBODY'S ESCALATION ──────────────────────────
  #
  # Scanned over the ROUTING SURFACES — the lifecycle/symptom TABLE ROWS and the
  # section HEADINGS — because those are what a reader acts on, and all three
  # original defects lived there (a row saying "cannot mint — escalate | Mr.
  # McRitchie", a row saying "escalate", and a heading calling it "The one honest
  # escalation"). Prose that WARNS against escalating is not a routing instruction
  # and must not be caught; a rule that cannot tell those apart would be dropped.
  #
  # A row earns the operator ONLY by naming the missing-file condition.
  def test_no_routing_row_sends_the_provisioned_deployer_case_to_the_operator
    offenders = routing_lines(read(SOP)).select do |line|
      line.match?(ESCALATION) && line.match?(/deployer|OP_ADMIN_SERVICE_ACCOUNT_TOKEN/i) &&
        !unprovisioned_case?(line)
    end

    assert_empty offenders.map(&:strip),
                 "a deployer refusal on a provisioned machine is SELF-SERVICE. Only the " \
                 "machine that has never been given a token (#{INSTALL}) is his."
  end

  # ── AN ESCALATION SECTION MUST SCOPE ITSELF ─────────────────────────────────
  #
  # The third defect spot was a section headed "The one honest escalation" whose
  # body said "A production deploy therefore needs Mr. McRitchie to supply it" —
  # true only of a machine that has never been provisioned, stated as the general
  # rule. Note what does NOT work as a test here: the heading names neither
  # "deployer" nor "admin", so a heading-keyword scan misses the very string it was
  # written for. (It did; mutation caught it.)
  #
  # The rule that holds: any section PROMISING an escalation must say WHICH machine
  # state earns it. An unscoped one is the defect, whatever it is titled.
  def test_every_escalation_section_scopes_itself_to_the_unprovisioned_machine
    offenders = sections(read(SOP)).select do |heading, body|
      heading.match?(ESCALATION) || body.match?(ESCALATION)
    end.reject do |_heading, body|
      body.lines.any? { |l| unprovisioned_case?(l) }
    end

    assert_empty offenders.map { |h, _| h.strip },
                 "a section that routes work to Mr. McRitchie without naming the " \
                 "missing-file condition reads as the GENERAL deployer answer — which " \
                 "is the belief that cost the 2026-08-30 session"
  end

  # ── 3. THE HONEST HALF MUST SURVIVE ─────────────────────────────────────────
  #
  # The opposite failure is just as bad: a doc that says "always self-service"
  # sends an agent on a fresh machine round a loop that cannot terminate. Deleting
  # the escalation entirely would pass test 2, so this pins it from the other side.
  def test_the_one_genuine_escalation_is_still_documented
    sop = read(SOP)

    assert_includes sop, INSTALL,
                    "a machine with no ~/.zprofile.admin genuinely needs Mr. McRitchie once"
    assert sop.lines.any? { |l| unprovisioned_case?(l) },
           "the escalation must be CONDITIONAL on the missing file, or it reads as " \
           "the general case again — which is the defect, restored"
  end

  # ── 4. THE TWO DOCS MUST AGREE ──────────────────────────────────────────────
  def test_the_sop_and_the_deeper_reference_do_not_contradict_each_other
    [SOP, DEEPER_REF].each do |doc|
      assert_includes read(doc), SELF_SERVICE,
                      "#{doc} describes the deployer refusal and must name the same remedy; " \
                      "two registered docs disagreeing is what sent the agent to the operator"
    end
  end

  # ── 5. A STEP MUST REPAIR THE SHELL IT IS RUN IN ────────────────────────────
  #
  # Step 4 prescribed `bin/gh-token --force >/dev/null`, which mints into the SHARED
  # CACHE and DISCARDS the token: the caller's GH_TOKEN is untouched, `gh` keeps
  # failing identically, and the reader loops back to the top of the SOP. Verified
  # independently by two reviewers. `bin/gh-auth-refresh --export` is the form that
  # rewrites the environment.
  def test_the_force_step_repairs_this_shell_rather_than_only_the_cache
    sop = read(SOP)

    refute_match(%r{bin/gh-token --force\s*>\s*/dev/null}, sop,
                 "this mints into the shared cache and throws the token away — the " \
                 "shell that is broken stays broken, so the reader loops")
    assert_match(%r{bin/gh-auth-refresh --force.*--export|eval "\$\(bin/gh-auth-refresh --force}, sop,
                 "the force step must name the command that exports into THIS shell")
  end

  # ── 6. NO REMEDY MAY REQUIRE THE THING THAT IS MISSING ──────────────────────
  #
  # The general form of the whole bug class. `op vault list` authenticates with the
  # very service-account token an absent-token refusal is reporting, so naming it
  # there is a remedy that cannot run.
  def test_a_missing_token_is_never_told_to_run_op
    %i[agent deployer].each do |lane|
      ENV.delete(OpVaults.token_env(lane))
      [true, false].each do |provisioned|
        message = with_provisioned(provisioned) { OpVaults.diagnose(lane) }

        refute_includes message, "op vault list",
                        "#{lane}/provisioned=#{provisioned}: `op` authenticates with the " \
                        "token this message says is missing, so it cannot run"
      end
    end
  end


  # ── A REMEDY MUST NOT PRINT A LIVE TOKEN ────────────────────────────────────
  #
  # FOUND IN REVIEW of this PR, and it is this PR's own defect class reappearing
  # inside its own fix. The deployer remedy prescribed:
  #     bin/gh-auth-refresh --identity deployer --export
  # Bare, that is `puts "export GH_TOKEN='<live installation token>'"`
  # (bin/gh-auth-refresh) — it writes a DEPLOYER credential into scrollback and
  # into every agent transcript that captures the run. It also cannot alter the
  # parent shell, so the "then re-run bin/release ship" that followed failed
  # identically. A remedy that leaks a secret AND does not work is strictly worse
  # than no remedy, because the reader ACTS on it.
  #
  # THE RIGHT ANSWER IS TO PRESCRIBE NOTHING THERE. The deployer is never cached
  # (bin/gh-token's CACHEABLE_IDENTITIES), so the next git operation mints fresh
  # through the credential helper on its own — `source` + `export GH_APP_ITEM` is
  # the entire fix. Wrapping it in `eval "$(...)"` would stop the leak but is
  # still wrong: the deployer App has NO pull_requests grant while bin/release
  # calls `gh pr view`/`create`/`merge`, so installing that token into `gh` makes
  # a later failure MORE likely.
  def test_no_remedy_prescribes_a_bare_exporting_refresh
    offenders = REMEDY_SOURCES.filter_map do |rel|
      body = File.read(File.join(ROOT, rel))
      body.each_line.with_index(1).filter_map { |line, n|
        # ONLY A PRESCRIPTION COUNTS — a line the reader would COPY. Prose that
        # merely explains what `--export` does is not a hazard, and an earlier
        # version of this guard flagged exactly that (token-session.md:115,
        # "`--export` is the half that repairs this shell"), which would have
        # taught the next editor to delete a correct sentence. A prescription is
        # a bare command: the line begins with it, up to leading whitespace or a
        # shell prompt, and carries no surrounding prose.
        # Strip the wrappers a prescription can arrive in: markdown indentation,
        # a shell prompt, and — the one an earlier version of this guard MISSED —
        # the opening quote of a Ruby string literal, which is how bin/release.rb
        # builds its messages. Without that, this guard read markdown only and
        # would have passed over the very file whose message caused the bounce.
        command = line.strip.sub(/\A"\s*/, "").sub(/\A[$>]\s*/, "")
        next unless command.start_with?("bin/gh-auth-refresh")
        next unless command.include?("--export")
        next if command.include?('eval "$(')

        "#{rel}:#{n}"
      }.presence
    end.flatten

    assert_empty offenders,
                 "a bare `--export` refresh PRINTS a live token and cannot repair the caller's " \
                 "shell; prescribe `eval \"$(...)\"` where a refresh is genuinely wanted, and " \
                 "nothing at all on the deployer lane, which mints fresh per push"
  end

  REMEDY_SOURCES = [
    "bin/release.rb",
    "docs/agents/modules/token-session.md"
  ].freeze

  private

  # The lines a reader ACTS on: markdown table rows.
  def routing_lines(text) = text.lines.select { |l| l.strip.start_with?("|") }

  # [heading, body] for every ## / ### section in the doc.
  def sections(text)
    text.split(/^(?=#{'#'}{2,3} )/).filter_map do |chunk|
      lines = chunk.lines
      next unless lines.first.to_s.start_with?("##")

      [lines.first, lines[1..].to_a.join]
    end
  end

  # Does this line scope itself to the machine that has never been provisioned?
  # Backticks around the path are optional — the doc uses them, the tool does not.
  def unprovisioned_case?(line)
    line.match?(/(?:has no|no)\s+`?~\/\.zprofile\.admin`?/) || line.include?(INSTALL)
  end

  def with_provisioned(value)
    OpVaults.singleton_class.send(:alias_method, :real_provisioned?, :provisioned?)
    OpVaults.define_singleton_method(:provisioned?) { |_ = nil| value }
    yield
  ensure
    OpVaults.singleton_class.send(:remove_method, :provisioned?)
    OpVaults.singleton_class.send(:alias_method, :provisioned?, :real_provisioned?)
    OpVaults.singleton_class.send(:remove_method, :real_provisioned?)
  end
end
