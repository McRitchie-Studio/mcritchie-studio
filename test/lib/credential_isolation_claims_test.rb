# frozen_string_literal: true

# [unit] What the two-vault split ACTUALLY guarantees, and what the docs are
# allowed to say about it.
#
# Sibling of test/lib/op_vaults_test.rb, which tests the MECHANISM. This file
# tests the CLAIMS — because the defect it was written for was not in the code.
# The code shipped correct on 2026-08-28 and is still correct; five prose sites
# then described it as stronger than it is, and one invented an incident to
# justify a line that needs no justification.
#
# ---------------------------------------------------------------------------
# DEFECT 1 — THE OVERCLAIM. Five sites said an ordinary agent shell is
# "structurally unable to READ an admin credential". Measured false at the time:
# bin/gh-token read its cache BEFORE minting, so `bin/gh-token --identity deployer`
# exited 0 in a shell that never sourced ~/.zprofile.admin. `never-cache-deployer-token`
# has since closed that window (CACHEABLE_IDENTITIES = %w[agent], checked before the
# read, with any stale slot purged).
#
# THE SCOPING RULE SURVIVES THE FIX, which is why this guard still earns its keep.
# What each file may promise is decided by what that file ENFORCES: the token map
# blocks the MINT, the cache rule stops the HOLDING. A sentence in one that claims
# the other is unsourced even when both happen to be true — and the next edit to
# either file breaks it silently.
#
# This is not pedantry about wording. A security boundary described as wider than
# it is gets trusted for things it does not cover, and the discovery arrives at a
# production deploy.
#
# DEFECT 2 — THE FABRICATED INCIDENT. Two sites said the old unanchored
# /OP_SERVICE_ACCOUNT_TOKEN/ matched OP_ADMIN_SERVICE_ACCOUNT_TOKEN "as a
# substring" and had "once silently deleted the admin token". It never did and
# could not: OP_ADMIN_ sits between OP_ and SERVICE_. The anchored form was KEPT
# — it is correct on its own merits — and only the invented history was deleted.
# ---------------------------------------------------------------------------
#
# WHY A SENTENCE SCAN RATHER THAN A LIST OF DELETED SENTENCES. A test that greps
# for the exact strings removed passes the moment somebody re-words the same false
# claim, which is the likeliest way it comes back. The rule below is the rule the
# prose has to follow: if a sentence says a build lane cannot HAVE an admin
# credential, it must scope that to the MINT / the 1Password read.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

class CredentialIsolationClaimsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  AGENT_VAR = "OP_SERVICE_ACCOUNT_TOKEN"
  ADMIN_VAR = "OP_ADMIN_SERVICE_ACCOUNT_TOKEN"

  # The four files that describe the boundary in prose.
  CLAIM_SITES = %w[
    bin/lib/op_vaults.rb
    bin/setup-1pass-token
    docs/agents/system/house-burn-down.md
    docs/agents/modules/credentials.md
  ].freeze

  # A sentence trips the rule when it denies a capability, names an admin
  # credential, and reaches for a verb STRONGER than the mechanism supports —
  # unless it also scopes itself to the mint / the 1Password read.
  # `fails` earns its place: op_vaults.rb phrased the overclaim with no negation at
  # all — "a build lane that REACHES FOR an admin credential FAILS" — so a denial
  # vocabulary built only from cannot/unable/never walked straight past the site
  # this file is named after. Measured: with the narrower pair, mutating that block
  # back killed only the required-claim test.
  DENIAL = /\b(?:unable|cannot|can(?:no|')t|never|impossible|fails?|failure)\b/i
  TOO_STRONG = /\b(?:read|reads|obtain|obtains|get|gets|hold|holds|access|accesses|
                    unreadable|reach|reaches|reaching)\b/xi
  ADMIN_SUBJECT = /\badmin (?:credential|credentials|secret|secrets|token|tokens)\b/i
  SCOPED_TO_THE_MINT = /\b(?:mint|mints|minting|1password read|op read)\b/i

  # The fabricated incident, in any rewording: the two variable names in one
  # sentence, joined by a substring/containment claim.
  # ORDER-INDEPENDENT, BY MEASUREMENT. The first version of this required the
  # containment word to sit BETWEEN the two names; the sentence actually deleted
  # reads "...on OP_SERVICE_ACCOUNT_TOKEN also matches OP_ADMIN_SERVICE_ACCOUNT_TOKEN
  # AS A SUBSTRING", which puts it after both — so restoring the real fabricated
  # sentence killed nothing. Both names plus a containment word, in one sentence,
  # in any order.
  CONTAINMENT_WORD = /\b(?:substring|contains?|contained|containment)\b/i

  # The incident itself, which is the operationally load-bearing half: the claim
  # that the agent install ONCE DELETED the admin token.
  DELETION_INCIDENT = /
    \b(?:silently\ )?(?:deleted|deleting|delete|removed|wiped|clobbered)\b
    [^.]{0,80}\badmin\b[^.]{0,40}\b(?:token|line|credential|one)\b
  /xi

  # A CORRECTION IS NOT THE CLAIM, and this file's own fix had to say the false
  # thing out loud in order to retract it. So a sentence carrying the claim is an
  # offender only when it neither DENIES it nor ATTRIBUTES it to a past version.
  # The rule the prose must follow: deny it, or report it as history — never
  # assert it. (Measured: without this guard the scan flagged the retraction in
  # bin/setup-1pass-token, i.e. the fix itself.)
  RETRACTED = /\b(?:not|never|neither)\s+(?:\S+\s+){0,3}(?:a\s+)?(?:substring|contains?|contain)\b/i
  # NOT /x — free-spacing mode would delete every literal space here and turn
  # "an earlier version" into "anearlierversion", which matches nothing. That is
  # exactly what it did on the first run: both retractions were reported as
  # offenders because their attribution marker was unmatchable.
  ATTRIBUTED = /\b(?:an earlier version|previously (?:claimed|said)|used to (?:say|claim)|this (?:comment|paragraph) claimed|once said)\b/i

  # ------------------------------------------------------------- the fact ----

  # The whole fabricated incident rests on this being true. It is not.
  def test_neither_token_variable_contains_the_other
    refute_includes ADMIN_VAR, AGENT_VAR,
                    "the fabricated incident requires #{AGENT_VAR} to be a substring of " \
                    "#{ADMIN_VAR}. It is not: OP_ADMIN_ sits between OP_ and SERVICE_."
    refute_includes AGENT_VAR, ADMIN_VAR

    assert_equal "OP_ADMIN_", ADMIN_VAR[0, ADMIN_VAR.index("SERVICE_ACCOUNT_TOKEN")],
                 "this is the exact reason the substring claim fails — pin it, so a rename " \
                 "that made the claim TRUE would fail here instead of silently vindicating " \
                 "a story that was never true"
  end

  # ----------------------------------------------------------- the replay ----

  # The empirical half: run the OLD unanchored pattern against a profile holding
  # both lines, in both orders, exactly as the deleted paragraph described.
  def test_the_old_unanchored_sed_never_touched_the_admin_line
    [[agent_line, admin_line], [admin_line, agent_line]].each do |lines|
      profile = write_profile(lines)
      sed("/#{AGENT_VAR}/d", profile)
      body = File.read(profile)

      assert_includes body, admin_line,
                      "replaying the OLD unanchored sed against #{lines.first.split('=').first.strip}-first " \
                      "must leave the admin line intact — it always did"
      refute_includes body, agent_line, "the agent line is the one it was supposed to remove"
    end
  end

  # CONTROL. Without this, the test above passes just as happily against a sed
  # that deletes nothing at all — and would then prove the opposite of what it
  # claims. This is the pattern that WOULD have eaten the admin line.
  def test_the_replay_harness_can_actually_delete_the_admin_line
    profile = write_profile([admin_line])
    sed("/SERVICE_ACCOUNT_TOKEN/d", profile)

    assert_equal "", File.read(profile).strip,
                 "the replay harness must be capable of deleting the admin line, or the " \
                 "survival asserted above is evidence of a broken command, not of a false claim"
  end

  # -------------------------------------------- the form the script ships ----

  def test_the_installed_removal_pattern_is_anchored
    line = File.read(script).each_line.find { |l| l.include?("sed -i") }

    assert line, "bin/setup-1pass-token must still remove the prior export line with sed"
    assert_includes line, '"/^export ${VAR}=/d"',
                    "the anchor is kept on its own merits — it takes the variable's own export " \
                    "line and not a comment mentioning the name. Found: #{line.strip}"
  end

  # The merits the anchor is actually kept for, exercised rather than asserted.
  def test_the_anchored_removal_replaces_cleanly_and_spares_the_other_lane
    decoys = [
      "# #{AGENT_VAR} is installed by bin/setup-1pass-token\n",
      "export #{AGENT_VAR}_BACKUP=ops_backup\n"
    ]
    profile = write_profile([agent_line("ops_old")] + decoys + [admin_line])

    2.times { sed("/^export #{AGENT_VAR}=/d", profile) }
    body = File.read(profile)

    refute_includes body, "ops_old", "the prior export line must be gone, so a re-run replaces"
    assert_includes body, admin_line, "the other lane's line must survive"
    decoys.each do |decoy|
      assert_includes body, decoy,
                      "the anchor must spare #{decoy.strip.inspect} — sparing these is the real " \
                      "reason it is anchored, and the reason the invented one was never needed"
    end
  end

  # ------------------------------------------------------------ the prose ----

  def test_no_file_re_asserts_the_fabricated_incident
    offenders = prose_files.flat_map do |rel|
      sentences(File.join(ROOT, rel)).filter_map do |sentence|
        premise = sentence.include?(AGENT_VAR) && sentence.include?(ADMIN_VAR) &&
                  sentence.match?(CONTAINMENT_WORD)
        next unless premise || sentence.match?(DELETION_INCIDENT)
        next if sentence.match?(RETRACTED) || sentence.match?(ATTRIBUTED)

        "#{rel}: #{sentence}"
      end
    end

    assert_empty offenders,
                 "the substring claim is FALSE (see test_neither_token_variable_contains_the_other) " \
                 "and was deleted on 2026-08-29. If a real containment bug is ever found, fix the " \
                 "code and this test — do not re-add the story."
  end

  def test_every_isolation_claim_is_scoped_to_the_mint
    offenders = CLAIM_SITES.flat_map do |rel|
      sentences(File.join(ROOT, rel)).filter_map do |sentence|
        next unless sentence.match?(DENIAL) && sentence.match?(ADMIN_SUBJECT) && sentence.match?(TOO_STRONG)
        next if sentence.match?(SCOPED_TO_THE_MINT)

        "#{rel}: #{sentence}"
      end
    end

    assert_empty offenders,
                 "a sentence denying a build lane an admin credential must scope itself to the " \
                 "MINT (the 1Password read), because that is what THIS boundary enforces. Not " \
                 "holding a deployer token is a separate mechanism in bin/gh-token, and an " \
                 "unscoped claim here silently depends on a rule another file owns — the kind " \
                 "of false that is only discovered at a production deploy."
  end

  # The other half of the same fix: deleting the overclaim must not leave the
  # boundary undescribed. Each site has to state the narrow claim positively.
  def test_each_site_states_the_narrow_claim
    # Normalised through `sentences`, because a comment marker and a line wrap sit
    # between "MINT an" and "admin credential" in bin/lib/op_vaults.rb — a raw-text
    # match reports that site missing when the sentence is right there.
    missing = CLAIM_SITES.reject do |rel|
      sentences(File.join(ROOT, rel)).any? { |s| s.match?(/\bMINT(?:ING)?\b an admin credential/) }
    end

    assert_empty missing,
                 "these files describe the two-vault boundary, so each must SAY what it is — " \
                 "that a build lane cannot MINT an admin credential. Scrubbing the overclaim " \
                 "without replacing it would satisfy the scan above and leave the reader with " \
                 "nothing."
  end

  # ------------------------------------------------- the vault name itself ----

  # THE STANDING RULE, made enforceable: never hardcode a vault name again.
  #
  # bin/lib/op_vaults.rb exists because "agents" was a literal in eleven places
  # and the rename broke all eleven at once. Two of them were still live when this
  # task was picked up, in the ONE script a fresh Mac runs first:
  # bin/ecosystem-build's `op read "op://agents/agent.alex.solana/private key"`
  # (verified failing against the real service account on 2026-08-29) and its
  # `grep -qw agents` vault guard, which passed only because -w treats the hyphen
  # in `agents-studio` as a word boundary — it would have gone red on
  # `agents_studio` and never consulted MCR_OP_VAULT_AGENT at all.
  #
  # A literal is the defect whether it names the OLD vault or the NEW one, so this
  # asks for the FORM, not for a blessed spelling.
  def test_no_script_resolves_a_vault_from_a_literal
    offenders = scripts.flat_map do |rel|
      body = File.read(File.join(ROOT, rel))
      found = []
      # \S, not . — `op://` followed by whitespace is prose naming the scheme
      # ("the op:// reference for one field"), not a reference with a vault in it.
      # Measured: with `.` this reported bin/lib/op_vaults.rb's own doc comment.
      body.scan(%r{op://(\S)}) { |c| found << "#{rel}: op://#{c.first}… — literal vault" unless "$#".include?(c.first) }
      body.scan(/--vault\s+["']?(\S)/) { |c| found << "#{rel}: --vault #{c.first}… — literal vault" unless "$#".include?(c.first) }
      found
    end

    assert_empty offenders.uniq,
                 "resolve the vault through ${MCR_OP_VAULT_AGENT:-agents-studio} (shell) or " \
                 "OpVaults.ref/vault (ruby). bin/lib/op_vaults.rb is the single source; a second " \
                 "literal only re-arms the 2026-08-28 outage for the next rename."
  end

  # The dead name specifically, in prose as well as code — a runbook that sends
  # the operator to `op://agents/...` fails at the worst possible moment.
  def test_the_renamed_vault_is_gone_everywhere
    offenders = (scripts + prose_files.grep(/\.md\z/)).uniq.filter_map do |rel|
      next if rel == SELF

      line = File.read(File.join(ROOT, rel)).each_line.with_index(1)
                 .find { |l, _n| l.include?("op://agents/") || l.match?(/--vault\s+["']?agents["']?\s/) }
      "#{rel}:#{line.last} #{line.first.strip}" if line
    end

    assert_empty offenders,
                 "the vault `agents` does not exist — the account holds agents-studio, " \
                 "agents-admin, agents-industries and agents-mcritchie-family. Verified " \
                 "2026-08-29: `op read 'op://agents/...'` answers \"agents\" isn't a vault " \
                 "in this account."
  end

  # The literal-vault scan above cannot see this one: the old guard was
  # `op vault list | grep -qw agents`, which carries no op:// and no --vault. It
  # passed against `agents-studio` ONLY because -w treats the hyphen as a word
  # boundary — an accident, not a check — and it never read MCR_OP_VAULT_AGENT.
  # bin/ecosystem-build is the first thing a fresh Mac runs, so its verdict on the
  # credential lane has to be a real one.
  def test_the_bringup_vault_guard_consults_the_override
    body = File.read(File.join(ROOT, "bin/ecosystem-build"))
    # COMMENT LINES STRIPPED. The fix's own comment QUOTES the old
    # `grep -qw agents` in order to explain why it went — and the first version of
    # this assertion read the whole file and flagged that explanation as the
    # offence. The claim is about executable code, so scan executable code.
    code = body.each_line.reject { |l| l.strip.start_with?("#") }.join

    refute_match(/grep\s+-\S*[wx]\S*\s+agents\b/, code,
                 "a word/substring match on a bare vault literal is not a vault check — " \
                 "this account holds four vaults whose names begin `agents`")
    assert_includes code, 'local agent_vault="${MCR_OP_VAULT_AGENT:-agents-studio}"',
                    "the guard must resolve the vault the way bin/lib/op_vaults.rb does"

    # "agent vault", not just "vault" — the op_secrets loop one function-block down
    # reports `log_fail "$var (op://$ref)" "... read on that vault?"`, which is
    # correct as it stands ($ref already carries the resolved vault) and is not
    # this guard's verdict.
    verdict = code.each_line.select { |l| l.match?(/log_(ok|fail)/) && l.include?("agent vault") }

    assert_operator verdict.size, :>=, 2, "expected both the pass and the fail verdict lines"
    verdict.each do |line|
      assert_includes line, "$agent_vault",
                      "the verdict must NAME the vault it actually looked for — the old failure " \
                      "message said \"can't read 'agents' vault\" long after `agents` stopped " \
                      "existing, sending the reader to check grants on a vault that is not there. " \
                      "Found: #{line.strip}"
    end
  end

  # THE LITERAL THE op:// SCAN CANNOT SEE. bin/ecosystem-build keeps its
  # 1Password-only secrets in a `vault/item/field` table and only later builds
  # `op read "op://$ref"` — so the vault name lives in a data string with no
  # `op://` and no `--vault` anywhere near it. It read `agents/agent.alex.solana`
  # until 2026-08-29 and was verified BROKEN against the real service account that
  # day, while every scheme-shaped scan reported the file clean. Measured: mutating
  # it back killed nothing until this test existed.
  def test_the_bringup_secret_map_resolves_its_vault_from_the_override
    body = File.read(File.join(ROOT, "bin/ecosystem-build"))
    block = body[/local op_secrets=\(\n(.*?)\n\s*\)/m, 1]

    assert block, "bin/ecosystem-build must still declare its 1Password-only secrets as op_secrets=(...)"

    entries = block.each_line.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

    refute_empty entries, "an empty map would pass this test vacuously"
    entries.each do |entry|
      ref = entry.delete('"').split("|")[2].to_s

      assert ref.start_with?("${MCR_OP_VAULT_AGENT:-agents-studio}/"),
             "every op_secrets ref must resolve its vault through the override — it is fed " \
             "straight into `op read \"op://$ref\"`. Found: #{ref.inspect}"
    end
  end

  private

  # This file quotes the dead reference in order to forbid it, so it must exempt
  # itself — otherwise the guard reports its own error message as the offence.
  SELF = "test/lib/credential_isolation_claims_test.rb"

  def scripts
    @scripts ||= Dir.chdir(ROOT) { Dir.glob("bin/**/*").select { |f| File.file?(f) } }
  end

  def script
    File.join(ROOT, "bin/setup-1pass-token")
  end

  def agent_line(value = "ops_agent_value")
    "export #{AGENT_VAR}=#{value}\n"
  end

  def admin_line(value = "ops_admin_value")
    "export #{ADMIN_VAR}=#{value}\n"
  end

  def write_profile(lines)
    dir = Dir.mktmpdir("zprofile")
    @tmpdirs = (@tmpdirs || []) << dir
    path = File.join(dir, "zprofile")
    File.write(path, lines.join)
    path
  end

  # BSD sed, as bin/setup-1pass-token invokes it (`/usr/bin/sed -i ''`), falling
  # back to GNU syntax so this runs on a Linux CI runner too.
  def sed(pattern, path)
    args = File.executable?("/usr/bin/sed") && RUBY_PLATFORM.include?("darwin") ?
      ["/usr/bin/sed", "-i", "", pattern, path] : ["sed", "-i", pattern, path]
    system(*args, exception: true)
  end

  # Comment markers stripped so a claim wrapped in `# ` reads as one sentence.
  def sentences(path)
    File.read(path)
        .gsub(/^\s*#\s?/, "")
        .split(/(?<=[.!?])\s+|\n{2,}/)
        .map { |s| s.gsub(/\s+/, " ").strip }
        .reject(&:empty?)
  end

  def prose_files
    @prose_files ||= Dir.chdir(ROOT) do
      (Dir.glob("docs/**/*.md") + Dir.glob("bin/**/*")).select { |f| File.file?(f) }
    end
  end

  def teardown
    (@tmpdirs || []).each { |d| FileUtils.remove_entry(d) }
  end
end
