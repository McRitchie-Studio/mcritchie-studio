# frozen_string_literal: true

require "test_helper"

# What docs/agents/modules/token-session.md is allowed to say about the four
# MECHANISMS a reviewer measured against it on 2026-09-27, the day after the SOP
# shipped (PR 1691). Each claim in the file was plausible, each was wrong, and each
# routed a reader somewhere useless:
#
#   1. `restore-agent-service-account` was named as the standing open escalation —
#      "it is Alex's", "arming this recipe does not close it" — while the board
#      already reported it ARCHIVED. It was archived because its premise (a service
#      account that no longer existed) was the stale environment step 1a resets. A
#      reader met a ticket that was closed, for a fault that was never real, in the
#      one section they reach when they are already out of ideas.
#   2. The hub's repo-local fallback was described as "not written by
#      bin/install-git-credential-helper (which writes `--global` only)". MEASURED:
#      that CLI writes NO git config, in either scope. It PRINTS a one-liner and the
#      operator runs it — its own --help says so. A reader who believes the doc goes
#      hunting for a writer that does not exist.
#   3. That fallback was quoted as `!gh auth git-credential`. The value in the hub's
#      .git/config is `!/opt/homebrew/bin/gh auth git-credential` — an absolute path.
#      Grep the short form and you find nothing, then conclude the fallback is
#      imaginary, which inverts the paragraph that explains the hub's symptom.
#   4. "The six other repos on this machine" named six and omitted `chain-ops`. A
#      sweep of all 19 checkouts found ONE repo-local `gh` fallback. A hand-kept
#      count of sibling repos has no feedback loop; this one went stale inside a day.
#
# WHY A PROPERTY SCAN RATHER THAN A LIST OF DELETED SENTENCES. A test that greps for
# the exact retired strings passes the moment somebody re-words the same false
# claim, which is the likeliest way one comes back. These assert the RULE the prose
# has to follow, and — where it can — the agreement between the doc and the source.
#
# SIBLINGS, NOT DUPLICATES. test/lib/token_session_sop_claims_test.rb pins WHO owns
# a credential refusal in that file; test/lib/app_id_recorded_claims_test.rb pins
# the hand-mint recipe's shape. Neither asks about these four mechanisms.
class TokenSessionMechanismClaimsTest < ActiveSupport::TestCase
  SOP = "docs/agents/modules/token-session.md"
  INSTALLER = "bin/install-git-credential-helper"
  INSTALLER_LIB = "bin/lib/credential_helper_install.rb"

  TASK_SLUG = "restore-agent-service-account"

  # The hub's repo-local helper, at the literal the config really holds.
  #
  # PINNED, NOT READ. The real value lives in a working copy's .git/config, which a
  # CI runner does not have, so this guard cannot measure it — the command that can
  # is recorded beside the claim in the SOP. What IS checkable everywhere is that
  # the short form never comes back.
  HUB_FALLBACK = "!/opt/homebrew/bin/gh auth git-credential"

  # EVERY LITERAL SPACE IS `\s+`, in both patterns below, and that is load-bearing.
  # `/x` is free-spacing mode: it DELETES literal whitespace from the pattern. A
  # sibling guard in this repo has carried `needs? Mr\. McRitchie` under /xi since
  # the day it shipped, which compiles to `needs?Mr\.McRitchie` and cannot match
  # English — so four of its five alternations have never fired. Measured
  # 2026-09-28. The controls below exist so that cannot happen here quietly.
  #
  # ROUTING language, not every mention of a name. A bare /Alex/ also matches "two
  # merges landed under Alex's own account" — narrative, in a section about a
  # different trap. A rule that flags prose nobody would act on is the rule the next
  # editor deletes, taking the real guard with it.
  ESCALATION = /escalat(?:e|ion|ing)|
                needs?\s+(?:Alex|Mr\.\s+McRitchie)|
                (?:Alex|Mr\.\s+McRitchie)\s+(?:must|has\s+to|needs?\s+to)|
                needs?\s+.{0,25}to\s+supply|
                ask\s+(?:him|the\s+operator|Alex|Mr\.\s+McRitchie)/xi

  # OWNERSHIP OF A UNIT OF WORK, which is how the retired clause actually routed:
  # "it is Alex's", with no escalation verb anywhere near it. MEASURED — restoring
  # that exact clause left the ESCALATION check above green, because it matches
  # verbs and the defect was a possessive.
  TASK_OWNERSHIP = /\b(?:is|are|remains?|stays?|belongs?\s+to)\s+
                     (?:still\s+)?
                     (?:Alex(?:'s)?|Mr\.\s+McRitchie(?:'s)?|his|the\s+operator(?:'s)?)\b/xi

  # A spelled-out or numeric count of sibling repositories. `19` is exempt: it is
  # the one number the SOP states WITH the sweep that produces it.
  REPO_COUNT = /\b(?:two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|
                     thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|
                     twenty|\d+)\s+(?:other\s+)?(?:repos|repositories|checkouts)\b/xi

  # ── 0. THE GUARD'S OWN VOCABULARY MUST BE ABLE TO MATCH ─────────────────────
  #
  # A control, because a regex that cannot match reports exactly the same green as
  # prose that is clean. Each row is a phrase its alternation exists for; a row that
  # stops matching means the alternation went dead, whatever the comment claims.
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

  # Prose each pattern must LEAVE ALONE. The narrowing is the reason a bare name
  # match was rejected, and an untested narrowing is not a narrowing.
  #
  # THE TWO LISTS DIFFER BY SCOPE, not by oversight. ESCALATION is read against a
  # whole section, so it has to survive every sentence in this SOP that names the
  # operator — including "that config is Alex's call", a true statement about who
  # decides a git config, in a section with no business naming a machine state.
  # TASK_OWNERSHIP is read only against the 320 characters following a task slug, so
  # config-ownership prose is out of its reach by construction; that is exactly why
  # it may be the broader pattern, and putting it under ESCALATION's list would have
  # forced it narrow enough to miss "it is Alex's" — the retired clause itself.
  ESCALATION_MUST_NOT_MATCH = [
    "two merges landed under Alex's own account",
    "that config is Alex's call",
    "Do not hand it to Alex",
    "the account was live the whole time"
  ].freeze

  OWNERSHIP_MUST_NOT_MATCH = [
    "the account was live the whole time",
    "arming this recipe does not close anything",
    "the bypass needs no broker"
  ].freeze

  test "[unit] every routing alternation can actually match the phrase it exists for" do
    ESCALATION_MUST_MATCH.each do |phrase|
      assert_match ESCALATION, phrase,
                   "ESCALATION cannot see #{phrase.inspect}. Under /x a literal space is " \
                   "DELETED from the pattern, so every multi-word alternation must spell " \
                   "its spaces \\s+"
    end

    OWNERSHIP_MUST_MATCH.each do |phrase|
      assert_match TASK_OWNERSHIP, phrase,
                   "TASK_OWNERSHIP cannot see #{phrase.inspect} — a dead branch under /x"
    end

    ESCALATION_MUST_NOT_MATCH.each do |phrase|
      refute_match ESCALATION, phrase,
                   "#{phrase.inspect} is narrative or a config decision, not a routing " \
                   "instruction. A rule that flags prose nobody would act on gets deleted"
    end

    OWNERSHIP_MUST_NOT_MATCH.each do |phrase|
      refute_match TASK_OWNERSHIP, phrase,
                   "#{phrase.inspect} carries no ownership claim; TASK_OWNERSHIP must not " \
                   "widen into ordinary prose about the bypass"
    end
  end

  # ── 1. A NAMED TASK MAY NOT STAND IN AS AN OPEN ESCALATION ──────────────────
  #
  # The rule: name a task in this SOP and you owe its state in the same breath.
  # FLATTEN-THEN-SUBSTRING, not a line regex — the offending clause wrapped across
  # three lines, and widening a line pattern to `\s+` does not save it, because a
  # line pattern cannot cross the newline a markdown paragraph puts there.
  test "[unit] a named task carries its board state and is not routed to the operator" do
    flat = flatten(read(SOP))

    assert_includes flat, TASK_SLUG, "guard the guard: the SOP still names the task"

    # THE WINDOW REACHES BOTH WAYS. Anchored forward only, it missed a restatement
    # that put the ownership clause BEFORE the slug ("Restoring one is the … task,
    # it is Alex's" splits either side of the name depending on the wrap) — measured
    # by mutation 2026-09-28, which passed green until this read backwards too.
    flat.to_enum(:scan, TASK_SLUG).each do
      match = Regexp.last_match
      window = "#{match.pre_match[-320..] || match.pre_match}#{TASK_SLUG}#{match.post_match[0, 320]}"

      assert_includes window, "archived",
                      "#{TASK_SLUG} is archived. A mention that does not say so reads as an " \
                      "open blocker, which is what sent four agents to the .pem bypass"
      refute_match ESCALATION, window,
                   "a closed task may not be handed to the operator — that is the escalation " \
                   "this SOP exists to remove, wearing a slug"
      refute_match TASK_OWNERSHIP, window,
                   "\"it is Alex's\" is the retired clause's own wording, and it routes without " \
                   "a single escalation verb. An archived task is nobody's"
    end
  end

  # ── 2. THE INSTALLER CLAUSE MUST NAME THE INSTALLER'S MECHANISM ─────────────
  #
  # DERIVED FROM THE SOURCE rather than pinned as prose, so the day the CLI does
  # start writing config this fails instead of vindicating a stale sentence.
  test "[unit] the installer clause agrees with what the installer does" do
    cli = read(INSTALLER)

    assert_includes cli, "never edits ~/.gitconfig",
                    "guard the guard: #{INSTALLER} must still disclaim writing config"
    refute_match(/^\s*(?:system|exec|IO\.popen).*git config --(?:global|local|replace)/, cli,
                 "#{INSTALLER} must still only PRINT the wiring — if it starts writing config, " \
                 "the SOP sentence this guards becomes the true one")

    flat = flatten(read(SOP))

    assert_includes flat, "writes no git config at all",
                    "#{SOP} must name the real mechanism: #{INSTALLER} prints, never writes"
    refute_match(/#{Regexp.escape(INSTALLER)}[^.]{0,60}\bwrites\b[^.]{0,40}--global/, flat,
                 "the retired claim, in any rewording: the CLI does not write a --global " \
                 "config. See #{INSTALLER_LIB} — git_config_command only builds a string")
  end

  # ── 3. THE HUB FALLBACK IS QUOTED AT ITS REAL, ABSOLUTE LITERAL ─────────────
  test "[unit] the hub fallback helper is quoted at its absolute path" do
    flat = flatten(read(SOP))

    assert_includes flat, HUB_FALLBACK,
                    "quote the value the hub's .git/config really holds. Re-read it with " \
                    "`git config --local --get-all credential.https://github.com.helper`"
    refute_includes flat, "`!gh auth git-credential`",
                    "the bare form is not a value anything holds — a reader greps for it, " \
                    "misses, and decides the fallback is imaginary"
  end

  # ── 4. THE REPO CENSUS IS ONE CHECKABLE CLAIM, WITH ITS COMMAND ─────────────
  #
  # A count nobody can re-run is the format that rots. The rule: no fixed count of
  # sibling repos in prose, and the narrowed claim ships with the sweep that settles
  # it — runnable as written, which was verified in both bash and zsh.
  test "[unit] the repo census is one claim and carries the command behind it" do
    body = read(SOP)
    flat = flatten(body)

    offenders = flat.scan(REPO_COUNT).reject { |hit| hit.match?(/\b19\b/) }

    assert_empty offenders,
                 "a spelled-out count of sibling repos cannot be re-run and went stale within " \
                 "a day (the six omitted chain-ops). State the one checkable claim and show " \
                 "the sweep"

    assert_includes flat, "the only checkout on this machine",
                    "narrow the census to one claim about one repo"
    assert_includes body, "--get-all credential.https://github.com.helper",
                    "every number in this paragraph needs the command beside it — the sweep " \
                    "that produced it must be in the doc, runnable as written"
  end

  # ── 5. THE MTIME LINE IS CONTEXT, NEVER A GATE ──────────────────────────────
  #
  # THE ONE THING THAT MUST NOT REGRESS. The SOP first told readers to check
  # `ls -la ~/.zprofile*` and treat "profile newer than your session" as the tell
  # that the environment was stale. It is refuted twice on the very cases it came
  # from: on 2026-09-27 the profile was two days OLDER than the failing session and
  # the reset worked; on 2026-09-28 it was three days older and the reset worked
  # again. As a gate it false-negatives straight into the `.pem` bypass, which is
  # the exact failure step 1a exists to prevent — so the line may stay as context
  # and may never sit inside the remedy a reader copies.
  test "[unit] the profile mtime is demoted to context and is not inside the remedy" do
    body = read(SOP)
    flat = flatten(body)

    assert_includes flat, "ls -la ~/.zprofile*",
                    "the mtime line is worth keeping as context; this guard demotes it, it " \
                    "does not delete it"
    assert_includes flat, "Do not gate this on the profile's mtime",
                    "the demotion must be stated where a reader meets the reset"

    # SCAN THE FENCES, do not pattern-match across one. `[^`]*` cannot reach inside
    # this block: its own comment quotes `User Type: SERVICE_ACCOUNT` in backticks,
    # so a backtick-excluding class stops dead and the guard reports "block is gone"
    # for a block that is right there. Measured while writing this test.
    remedy = body.scan(/```bash\n(.*?)```/m).flatten
                 .find { |block| block.include?("unset OP_SERVICE_ACCOUNT_TOKEN") }
    refute_nil remedy, "step 1a's reset block is gone — that block IS the remedy"
    refute_includes remedy, "ls -la",
                    "a context command at the head of a copyable remedy block reads as step " \
                    "one of the remedy. Keep it in the prose, out of the block"
  end

  private

  def read(rel) = Rails.root.join(rel).read

  # WHOLE-FILE FLATTEN, then substring. Every claim corrected in this pass wrapped
  # across lines, and two put their subject and their predicate on different lines.
  def flatten(text) = text.gsub(/\s+/, " ")
end
