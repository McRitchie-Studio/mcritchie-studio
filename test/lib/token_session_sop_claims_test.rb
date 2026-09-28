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
  # EVERY LITERAL SPACE IS `\s+`, AND THAT IS THE WHOLE POINT. `/x` is free-spacing
  # mode: it DELETES literal whitespace from the pattern. Written with plain spaces —
  # as this constant was from the day it shipped until 2026-09-28 — the alternations
  # compiled to `needs?Mr\.McRitchie`, `Mr\.McRitchie(?:must|hasto|needs?to)`,
  # `needs?.{0,25}tosupply` and `ask(?:him|theoperator|Mr\.McRitchie)`, none of which
  # can match English. MEASURED: four of the five alternations matched NOTHING, so
  # `escalat(?:e|ion|ing)` was carrying this regex alone, and the narrowing the
  # comment below describes was never in force. The sibling guard records the same
  # trap in its own header (test/lib/credential_isolation_claims_test.rb, RETRACTED)
  # — it was written there and not applied here.
  #
  # BOTH SPELLINGS OF THE OPERATOR. The soul rename landed 2026-09-24 and this SOP
  # was reworded to "Alex" with it, while the pattern still named only
  # "Mr. McRitchie"; the archive snapshots still carry the old spelling, so neither
  # can be dropped.
  #
  # NOTE the `escalat(?:e|ion)` alternation. Written as bare /escalate/ this missed
  # the original defect's own heading, "The one honest escalation" — the exact string
  # it was written to catch. Caught by mutation, not by review.
  # ROUTING language, not every mention of a name. A bare /Alex/ also matches
  # "two merges landed under Alex's own account" — narrative, in a section about a
  # different trap entirely. A rule that flags prose nobody would act on gets
  # deleted by the next person, taking the real guard with it.
  ESCALATION = /escalat(?:e|ion|ing)|
                needs?\s+(?:Mr\.\s+McRitchie|Alex)|
                (?:Mr\.\s+McRitchie|Alex)\s+(?:must|has\s+to|needs?\s+to)|
                needs?\s+.{0,25}to\s+supply|
                ask\s+(?:him|the\s+operator|Mr\.\s+McRitchie|Alex)/xi

  def read(rel) = File.read(File.join(ROOT, rel))

  # ── 0. THE GUARD'S OWN VOCABULARY MUST BE ABLE TO MATCH ─────────────────────
  #
  # A control for ESCALATION, added 2026-09-28 after measuring that four of its five
  # alternations had never matched anything: `/x` strips the literal spaces, and every
  # multi-word alternation was silently unreachable. Nothing failed, because a regex
  # that cannot match reports the same green as prose that is clean.
  #
  # Each row is a phrase the alternation above EXISTS for. A row that stops matching
  # means the alternation went dead again, whatever the comment beside it claims.
  ESCALATION_MUST_MATCH = [
    "The one honest escalation",
    "escalate to the operator",
    "this needs Alex",
    "this needs Mr. McRitchie",
    "Alex must supply it",
    "Mr. McRitchie has to run it",
    "Alex needs to run it",
    "it needs the admin profile to supply it",
    "ask him",
    "ask the operator",
    "ask Alex"
  ].freeze

  # Prose the regex must LEAVE ALONE. The narrowing is the reason a bare name match
  # was rejected, and until this control existed the narrowing was untested too.
  ESCALATION_MUST_NOT_MATCH = [
    "two merges landed under Alex's own account",
    "that config is Alex's call",
    "Do not hand it to Alex",
    "everything else here is yours"
  ].freeze

  def test_every_ownership_alternation_can_actually_match
    OWNERSHIP_MUST_MATCH.each do |phrase|
      assert_match TASK_OWNERSHIP, phrase,
                   "TASK_OWNERSHIP cannot see #{phrase.inspect} — a dead branch under /x"
    end

    refute_match TASK_OWNERSHIP, "the account was live the whole time",
                 "ownership language only; this is narrative"
  end

  def test_every_escalation_alternation_can_actually_match
    ESCALATION_MUST_MATCH.each do |phrase|
      assert_match ESCALATION, phrase,
                   "ESCALATION cannot see #{phrase.inspect}. Under /x a literal space is " \
                   "DELETED from the pattern, so every multi-word alternation must spell " \
                   "its spaces \\s+ — that is how this regex spent its whole life with " \
                   "four dead branches"
    end

    ESCALATION_MUST_NOT_MATCH.each do |phrase|
      refute_match ESCALATION, phrase,
                   "ESCALATION flags #{phrase.inspect}, which is narrative or a config " \
                   "decision, not a routing instruction. A rule that flags prose nobody " \
                   "would act on is the rule the next editor deletes"
    end
  end

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

  # ── 7. A NAMED TASK MAY NOT STAND IN AS AN OPEN ESCALATION ──────────────────
  #
  # FOUND IN REVIEW of PR 1691 (Carl, 2026-09-27). The bypass section said
  # "Restoring one is the `restore-agent-service-account` task, it is Alex's, and
  # arming this recipe does not close it" — while the board already reported that
  # task ARCHIVED, archived precisely because its premise (a destroyed service
  # account) was the stale environment step 1a resets. So the SOP pointed a reader
  # at a ticket that was closed, for a fault that was never real, in the one
  # section a reader arrives at when they are already out of ideas.
  #
  # NOT A GREP FOR THE DELETED SENTENCE. The rule: name a task here and you owe its
  # state in the same breath. FLATTEN-THEN-SUBSTRING, not a line regex — the
  # offending clause wrapped across three lines and `\s+` does not save a line
  # pattern, because the claim and its subject never share a line.
  TASK_SLUG = "restore-agent-service-account"

  # OWNERSHIP OF A UNIT OF WORK, which is how the retired clause actually routed:
  # "it is Alex's", with no escalation verb anywhere near it. MEASURED — restoring
  # that exact clause left this test green until this pattern was added, because
  # ESCALATION matches verbs and the defect was a possessive.
  #
  # DELIBERATELY NOT FOLDED INTO ESCALATION. That regex is shared by the
  # section-level and routing-row tests, and a bare possessive there flags
  # "that config is Alex's call" — a true sentence about a config decision, in a
  # section with no business naming the unprovisioned machine. A rule that flags
  # prose nobody would act on is the rule the next editor deletes.
  # SPACES SPELLED `\s+`, for the reason ESCALATION documents above. Written with
  # plain spaces this compiled `belongs?to`, `Mr\.McRitchie` and `theoperator` —
  # three dead branches out of seven, in a pattern added in the same commit that
  # fixed the same bug ten lines up. Measured, then fixed.
  TASK_OWNERSHIP = /\b(?:is|are|remains?|stays?|belongs?\s+to)\s+
                     (?:still\s+)?
                     (?:Alex(?:'s)?|Mr\.\s+McRitchie(?:'s)?|his|the\s+operator(?:'s)?)\b/xi

  # Every branch of TASK_OWNERSHIP, with the phrase it exists for. Same control as
  # ESCALATION_MUST_MATCH, same reason.
  OWNERSHIP_MUST_MATCH = [
    "it is Alex's",
    "the task is Alex",
    "these are Alex's",
    "it remains Alex's",
    "it stays Alex's",
    "it belongs to Alex",
    "it is still Alex's",
    "it is Mr. McRitchie's",
    "that step is his",
    "it is the operator's"
  ].freeze

  def test_a_named_task_carries_its_board_state_and_is_not_routed_to_the_operator
    flat = flatten(read(SOP))

    assert_includes flat, TASK_SLUG, "guard the guard: the SOP still names the task"

    flat.to_enum(:scan, TASK_SLUG).each do
      window = Regexp.last_match.post_match[0, 320]

      assert_includes window, "archived",
                       "#{TASK_SLUG} is archived. A mention that does not say so reads as " \
                       "an open blocker, which is what sent four agents to the .pem bypass"
      refute_match ESCALATION, window,
                   "a closed task may not be handed to the operator — that is the " \
                   "escalation this SOP exists to remove, wearing a slug"
      refute_match TASK_OWNERSHIP, window,
                   "\"it is Alex's\" is the retired clause's own wording, and it routes " \
                   "without a single escalation verb. An archived task is nobody's"
    end
  end

  # ── 8. THE INSTALLER CLAUSE MUST NAME THE INSTALLER'S MECHANISM ─────────────
  #
  # The same review: the SOP described the hub's repo-local fallback as "not
  # written by bin/install-git-credential-helper (which writes `--global` only)".
  # MEASURED: that CLI writes NO git config, in either scope. It PRINTS a
  # `--global` one-liner and the operator runs it, which is stated in its own
  # --help and in the module behind it. A reader who believes the doc goes looking
  # for a writer that does not exist, and the config they are chasing was set by
  # hand.
  #
  # DERIVED FROM THE SOURCE rather than pinned as prose, so the day the CLI does
  # start writing config this fails instead of vindicating a stale sentence.
  INSTALLER = "bin/install-git-credential-helper"
  INSTALLER_LIB = "bin/lib/credential_helper_install.rb"

  def test_the_installer_clause_agrees_with_the_installer
    cli = read(INSTALLER)

    assert_includes cli, "never edits ~/.gitconfig",
                    "guard the guard: #{INSTALLER} must still disclaim writing config"
    refute_match(/^\s*(?:system|exec|`|IO\.popen).*git config --(?:global|local|replace)/, cli,
                 "#{INSTALLER} must still only PRINT the wiring — if it starts writing " \
                 "config, the SOP sentence this guards becomes the true one")

    flat = flatten(read(SOP))

    assert_includes flat, "writes no git config at all",
                     "#{SOP} must name the real mechanism: #{INSTALLER} prints, never writes"
    refute_match(/#{Regexp.escape(INSTALLER)}[^.]{0,60}\bwrites\b[^.]{0,40}--global/, flat,
                 "the retired claim, in any rewording: the CLI does not write a --global " \
                 "config. See #{INSTALLER_LIB} — git_config_command only builds a string")
  end

  # ── 9. THE HUB FALLBACK IS QUOTED AT ITS REAL, ABSOLUTE LITERAL ─────────────
  #
  # The SOP quoted the hub's repo-local helper as `!gh auth git-credential`. The
  # value in the hub's .git/config is `!/opt/homebrew/bin/gh auth git-credential`
  # — an absolute path. A reader who greps for the short form finds nothing and
  # concludes the fallback is not there, which inverts the whole paragraph.
  #
  # PINNED, NOT READ. The real value lives in a working copy's .git/config, which
  # a CI runner does not have, so this guard cannot measure it. The command that
  # does is recorded beside the claim in the SOP. What IS checkable in CI is that
  # the short form never comes back.
  HUB_FALLBACK = "!/opt/homebrew/bin/gh auth git-credential"

  def test_the_hub_fallback_is_quoted_at_its_absolute_path
    flat = flatten(read(SOP))

    assert_includes flat, HUB_FALLBACK,
                     "quote the value the hub's .git/config really holds. Re-read it with " \
                     "`git config --local --get-all credential.https://github.com.helper`"
    refute_includes flat, "`!gh auth git-credential`",
                    "the bare form is not a value anything holds — a reader greps for it, " \
                    "misses, and decides the fallback is imaginary"
  end

  # ── 10. THE REPO CENSUS IS ONE CHECKABLE CLAIM, WITH ITS COMMAND ────────────
  #
  # The SOP enumerated "the six other repos on this machine" and named six. A
  # reviewer swept ALL NINETEEN checkouts under /Users/alex/projects and found one
  # repo-local `gh` fallback; `chain-ops` was missing from the six entirely. A
  # count nobody can re-run is the format that rots, so the rule is: no fixed
  # count of sibling repos in prose, and the narrowed claim ships with the sweep
  # that settles it.
  REPO_COUNT_WORDS = /\b(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|
                          thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|
                          twenty|\d+)\s+(?:other\s+)?(?:repos|repositories|checkouts)\b/xi

  def test_the_repo_census_is_one_claim_and_carries_its_command
    body = read(SOP)
    flat = flatten(body)

    offenders = flat.scan(REPO_COUNT_WORDS).reject { |hit| hit.match?(/\b19\b/) }

    assert_empty offenders,
                 "a spelled-out count of sibling repos cannot be re-run and went stale " \
                 "within a day (the six omitted chain-ops). State the one checkable " \
                 "claim and show the sweep"

    assert_includes flat, "the only checkout on this machine",
                     "narrow the census to one claim about one repo"
    assert_includes body, "--get-all credential.https://github.com.helper",
                     "every number in this paragraph needs the command beside it — the " \
                     "sweep that produced it must be in the doc, runnable as written"
  end

  REMEDY_SOURCES = [
    "bin/release.rb",
    "docs/agents/modules/token-session.md"
  ].freeze

  private

  # WHOLE-FILE FLATTEN, then substring. Measured twice on 2026-09-28: every claim
  # corrected in this pass wrapped across lines, and two of them put their subject
  # and their predicate on different lines, so no line-anchored pattern could see
  # them. Widening a line pattern to `\s+` does not help — it cannot cross the
  # newline a markdown paragraph puts there, and in a Ruby or shell source the
  # continuation line opens with a comment marker.
  def flatten(text) = text.gsub(/\s+/, " ")

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
