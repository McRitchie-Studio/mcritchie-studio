# frozen_string_literal: true

# [unit] The two-vault split as the scripts implement it: bin/setup-1pass-token
# replaces only its own lane's export line, and every script resolves a vault
# through an override (bin/lib/op_vaults.rb#LANES), never a literal.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

class CredentialVaultResolutionTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  AGENT_VAR = "OP_SERVICE_ACCOUNT_TOKEN"
  ADMIN_VAR = "OP_ADMIN_SERVICE_ACCOUNT_TOKEN"

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

  # ------------------------------------------------- the vault name itself ----

  # THE STANDING RULE, made enforceable: never hardcode a vault name again.
  #
  # bin/lib/op_vaults.rb exists because "agents" was a literal in eleven places
  # and the rename broke all eleven at once. Two of them were still live when this
  # task was picked up, in the ONE script a fresh Mac runs first:
  # bin/ecosystem-build's `op read "op://agents/agent.alex.solana/private key"`
  # (verified failing against the real service account on 2026-08-29) and its
  # `grep -qw agents` vault guard, which passed only because -w treats the hyphen
  # in `studio-agents` as a word boundary — it would have gone red on
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
                 "resolve the vault through ${MCR_OP_VAULT_AGENT:-studio-agents} (shell) or " \
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
                 "the vault `agents` does not exist — the account holds studio-agents, " \
                 "studio-agents-admin, industries-agents and family-agents. Verified " \
                 "2026-08-29: `op read 'op://agents/...'` answers \"agents\" isn't a vault " \
                 "in this account."
  end

  # The literal-vault scan above cannot see this one: the old guard was
  # `op vault list | grep -qw agents`, which carries no op:// and no --vault. It
  # passed against `studio-agents` ONLY because -w treats the hyphen as a word
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
    assert_includes code, 'local agent_vault="${MCR_OP_VAULT_AGENT:-studio-agents}"',
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

  # THE LITERAL THE op:// SCAN CANNOT SEE. bin/ecosystem-build kept its
  # 1Password-only secrets in a `vault/item/field` table and only later built
  # `op read "op://$ref"` — so the vault name lived in a data string with no
  # `op://` and no `--vault` anywhere near it. It read `agents/agent.alex.solana`
  # until 2026-08-29 and was verified BROKEN against the real service account that
  # day, while every scheme-shaped scan reported the file clean.
  #
  # The table's one entry wrote SOLANA_ADMIN_KEY (a mainnet Squads seat) into the
  # turf .env, and it was RETIRED on 2026-10-06 (local-envs-drop-mainnet-keys):
  # SOLANA_ADMIN_KEY heads the production-only deny list. So the guard now has
  # two halves. If a table comes back, every ref must still resolve its vault
  # through an MCR_OP_VAULT_* override, AND it may never carry a deny-listed key.
  def test_the_bringup_secret_map_resolves_its_vault_and_writes_no_production_only_key
    require_relative "../../bin/lib/dev_secret_key"
    body = File.read(File.join(ROOT, "bin/ecosystem-build"))
    block = body[/local op_secrets=\(\n(.*?)\n\s*\)/m, 1]

    unless block
      refute_match(/^[^#\n]*op read "op:\/\/\$ref"/, body,
                   "an op:// read of a table ref with no op_secrets=(...) table is a map this guard cannot see")
      return
    end

    entries = block.each_line.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
    refute_empty entries, "an empty map would pass this test vacuously"
    entries.each do |entry|
      _app, var, ref = entry.delete('"').split("|")
      refute_includes DevSecretKey::PRODUCTION_ONLY_KEYS, var,
                      "op_secrets may not write a production-only key into a local .env"
      vault = ref.to_s.split("/").first.to_s

      if (m = vault.match(/\A\$([A-Za-z_][A-Za-z0-9_]*)\z/))
        binding_line = /(?:local\s+)?#{Regexp.escape(m[1])}="\$\{MCR_OP_VAULT_[A-Z_]+:-[^}]+\}"/
        assert_match binding_line, body,
                     "op_secrets resolves its vault from $#{m[1]}, but nothing in " \
                     "bin/ecosystem-build binds that name from an MCR_OP_VAULT_* override — " \
                     "so it is a literal wearing a variable's clothes."
      else
        assert_match(/\A\$\{MCR_OP_VAULT_[A-Z_]+:-[^}]+\}\z/, vault,
                     "every op_secrets ref must resolve its vault through an MCR_OP_VAULT_* " \
                     "override — it is fed straight into `op read \"op://$ref\"`. " \
                     "Found: #{ref.inspect}")
      end
    end
  end

  private

  # This file quotes the dead reference in order to forbid it, so it must exempt
  # itself — otherwise the guard reports its own error message as the offence.
  SELF = "test/lib/credential_vault_resolution_test.rb"

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

  def prose_files
    @prose_files ||= Dir.chdir(ROOT) do
      (Dir.glob("docs/**/*.md") + Dir.glob("bin/**/*")).select { |f| File.file?(f) }
    end
  end

  def teardown
    (@tmpdirs || []).each { |d| FileUtils.remove_entry(d) }
  end
end
