# frozen_string_literal: true

# [unit] + [integration] bin/ecosystem-build's agent-vault guard, EXECUTED.
#
# WHY THIS FILE EXISTS, and why it is not more assertions in
# test/lib/credential_isolation_claims_test.rb. That file guards the SOURCE TEXT
# of this guard — that it names $agent_vault in its verdict, that it resolves the
# name through MCR_OP_VAULT_AGENT, that no `grep -w` survives. Every one of those
# is a statement about a string. None of them runs the guard, and the defect they
# were written for was a guard that read correctly and ANSWERED WRONG:
# `op vault list | grep -qw agents` reported the credential lane healthy against
# `studio-agents`, because -w treats a hyphen as a word boundary. A script whose
# only test is a scan of its own text can be wrong in exactly that way forever.
#
# So this file stubs `op` and asks the guard questions.
#
# THE FOUR VAULTS ARE THE WHOLE POINT. The account holds studio-agents,
# studio-agents-admin, industries-agents and family-agents. "Contains the word
# agents" is true of all four and of the vault `agents`, which has not existed
# since 2026-08-28 — so a match that is not an EXACT one answers a question
# nobody asked.
#
# AND IT MUST FAIL CLOSED. A guard is a claim that something was checked. Absent,
# empty, non-JSON or non-array output from `op` is not evidence a vault is
# reachable, so each of those has to land on "no" rather than on a shrug.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class EcosystemBuildVaultGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")

  # `op vault list --format=json`, as the 1PASSWORD ACCOUNT answers it — not as the
  # agent service account does. Per docs/agents/modules/credential-inventory.md the
  # agent token is granted studio-agents alone. The fuller listing is deliberate:
  # more near-miss names is a STRICTLY HARDER test for an exact matcher.
  REAL_LISTING = <<~JSON
    [
      {"id":"aaa","name":"studio-agents"},
      {"id":"bbb","name":"studio-agents-admin"},
      {"id":"ccc","name":"industries-agents"},
      {"id":"ddd","name":"family-agents"}
    ]
  JSON

  VISIBLE = 0
  NOT_IN_LISTING = 1
  CANNOT_CHECK = 2

  # ------------------------------------------------------- the exact match ----

  def test_the_real_vault_is_visible
    assert_equal VISIBLE, guard("studio-agents", op: REAL_LISTING),
                 "studio-agents is in the listing, matched on its exact name"
  end

  # THE REGRESSION. `grep -qw agents` returned 0 here — that is the bug, in one
  # assertion. Mutate the guard back to a word match and this is the test that
  # goes red.
  def test_the_dead_vault_is_not_visible_even_though_four_names_contain_it
    assert_equal NOT_IN_LISTING, guard("agents", op: REAL_LISTING),
                 "the vault `agents` was renamed on 2026-08-28 and does not exist. Four " \
                 "vault names CONTAIN it, so any word/substring/prefix match says yes here " \
                 "— which is precisely how the old guard certified a broken credential lane"
  end

  # The old guard's other half: `-w` would have gone RED on an underscore, so it
  # was not even consistently wrong. An exact match is indifferent to the
  # separator and simply says no.
  def test_an_underscored_near_miss_is_not_visible
    assert_equal NOT_IN_LISTING, guard("agents_studio", op: REAL_LISTING)
  end

  def test_a_longer_name_sharing_the_prefix_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: '[{"name":"studio-agents-old"}]'),
                 "a listing entry that merely STARTS WITH the wanted name is a different vault"
  end

  # The other lane, so the match is shown to be about names rather than about
  # one blessed spelling.
  def test_the_admin_vault_is_visible_under_its_own_name
    assert_equal VISIBLE, guard("studio-agents-admin", op: REAL_LISTING)
  end

  # ------------------------------------------------------- failing closed ----

  def test_an_empty_listing_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: "[]")
  end

  def test_no_output_at_all_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: ""),
                 "silence is not a yes"
  end

  # The exit code is asserted EXACTLY, not merely "nonzero". jq answers a parse
  # error with 5 and no-output with 4, and the first version of the guard
  # returned those raw — harmless today, since the caller's case routes anything
  # that is not 0 or 2 to the grant message, and a trap tomorrow for whoever
  # reads a function documenting two codes and finds it emitting four.
  def test_garbage_output_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: "[ERROR] 2026/08/29 not authenticated"),
                 "unparseable output is a refusal, reported with the same code as any other " \
                 "listing that did not say yes"
  end

  # The reason `type == "array"` is in the jq filter — and the FIXTURE IS THE
  # TEST. This started as `{"name":"studio-agents"}`, which the filter refuses
  # with or without the type check (`.[]` yields the string, and `.name?` on a
  # string is empty), so deleting the type check killed nothing and the
  # assertion proved only that jq dislikes one particular object. A keyed map of
  # vaults is the shape that separates them: without `type == "array"` this
  # answers YES.
  def test_json_that_is_not_a_listing_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: '{"personal":{"name":"studio-agents"}}'),
                 "an object is not a vault listing, whatever its values happen to contain"
  end

  def test_a_failing_op_is_not_visible
    assert_equal NOT_IN_LISTING, guard("studio-agents", op: REAL_LISTING, op_status: 1),
                 "op exiting nonzero — no grants, an expired token, no network — is a no, " \
                 "not a maybe"
  end

  # ------------------------------- the diagnosis, which is its own defect ----

  # An operator sent to "check the token's vault grants" when the real fault is
  # an uninstalled binary spends the afternoon in the 1Password console. The two
  # failures are reported apart because they need opposite responses.
  def test_a_missing_op_binary_is_reported_as_uncheckable_not_as_a_grant_problem
    assert_equal CANNOT_CHECK, guard("studio-agents", op: nil)
  end

  def test_a_missing_jq_binary_is_reported_as_uncheckable_not_as_a_grant_problem
    assert_equal CANNOT_CHECK, guard("studio-agents", op: REAL_LISTING, jq: false)
  end

  # ------------------------------------------------------------ the wiring ----

  # [integration] The unit tests above prove the FUNCTION is right. They cannot
  # see whether phase_secrets still calls it, or whether its three exit codes are
  # still routed to three different verdicts — and a guard that is correct and
  # unwired is exactly as useful as no guard. So this drives the phase itself,
  # with the token set and every binary it reaches for stubbed.
  #
  # phase_secrets returns 1 at the Heroku step in all three cases (the stub
  # `heroku` refuses), which is what keeps this from running a real bringup. The
  # assertion is on the verdict line the vault guard printed on the way past.
  def test_phase_secrets_routes_each_guard_outcome_to_its_own_verdict
    ok = phase_secrets(op: REAL_LISTING)

    assert_match(/agent vault 'studio-agents' visible/, ok)
    refute_match(/can't see|can't check/, ok)

    grants = phase_secrets(op: "[]")

    assert_match(/can't see the 'studio-agents' agent vault/, grants)
    assert_match(/check the token's vault grants/, grants)

    uninstalled = phase_secrets(op: nil)

    assert_match(/can't check the 'studio-agents' agent vault/, uninstalled)
    assert_match(/op and jq are not both installed/, uninstalled)
    refute_match(/check the token's vault grants/, uninstalled,
                 "the missing-binary path must NOT send the reader to the 1Password console")
  end

  # The override, exercised rather than asserted. credential_isolation_claims_test
  # pins the resolution LINE; this proves the value actually reaches the guard.
  def test_the_phase_honours_the_vault_override
    out = phase_secrets(op: '[{"name":"vault-on-this-machine"}]',
                        env: { "MCR_OP_VAULT_AGENT" => "vault-on-this-machine" })

    assert_match(/agent vault 'vault-on-this-machine' visible/, out,
                 "MCR_OP_VAULT_AGENT is the escape hatch for a machine whose vaults are " \
                 "named differently — the failure mode bin/lib/op_vaults.rb was written for")
  end

  # ------------------------------------------------- the dispatch guard ----

  # [unit] Everything above depends on `source bin/ecosystem-build` defining the
  # script's functions and RUNNING NOTHING, which is a behaviour this task added.
  # It has to be right in BOTH directions, and the dangerous direction is the
  # quiet one: a guard that never fires turns the first script a fresh Mac runs
  # into a no-op that exits 0, and nothing says so until somebody rebuilds a
  # machine. That is the same silent-success failure as /tasks/ship-must-not-exit-zero,
  # so it gets a test rather than a reading.
  #
  # `main` is replaced with an echo in a COPY. The real one installs Homebrew
  # packages and bounces production-adjacent servers; there is no version of
  # this test that runs it.
  def test_main_runs_when_executed_and_stays_silent_when_sourced
    body = File.read(SCRIPT)
    neutered = body.sub(/^main\(\) \{.*?^\}$/m, %(main() { echo "MAIN RAN"; }))

    refute_equal body, neutered, "expected a top-level `main() { ... }` block to replace"

    Dir.mktmpdir("ecosystem-build-dispatch") do |tmp|
      copy = File.join(tmp, "ecosystem-build")
      File.write(copy, neutered)
      FileUtils.chmod(0o755, copy)
      env = { "HOME" => tmp, "PROJECTS_DIR" => tmp }

      executed, = Open3.capture2e(env, "bash", copy)
      sourced, = Open3.capture2e(env, "bash", "-c", %(source "#{copy}"))

      assert_match(/MAIN RAN/, executed,
                   "run directly, the script must still do its job — a dispatch guard that " \
                   "never fires is a bringup script that silently does nothing")
      refute_match(/MAIN RAN/, sourced,
                   "sourced, it must define its functions and run nothing")
      assert_match(/^agent_vault_visible$/, functions_after_sourcing(copy, env),
                   "and sourcing must actually leave the guard defined, or the silence above " \
                   "is the silence of a file that failed to parse")
    end
  end

  private

  def functions_after_sourcing(script, env)
    out, = Open3.capture2e(env, "bash", "-c", %(source "#{script}"; declare -F | sed 's/^declare -f //'))
    out
  end

  # Run `agent_vault_visible <want>` with a synthetic `op` on PATH, and return
  # its exit code.
  #
  # `op: nil` means the binary is absent. `jq: false` means jq is absent — worth
  # stubbing separately, because jq is the half a reader assumes is always there.
  def guard(want, op:, op_status: 0, jq: true, env: {})
    drive(%(agent_vault_visible "#{want}"), op: op, op_status: op_status, jq: jq, env: env).last
  end

  # Drive the whole phase. HEROKU_API_KEY is left unset on purpose so the phase
  # walks into the stubbed `heroku`, which refuses — the run always ends red, and
  # what is under test is what it printed before it got there.
  def phase_secrets(op:, env: {})
    out, = drive("phase_secrets", op: op, jq: true,
                                env: { "OP_SERVICE_ACCOUNT_TOKEN" => "ops_stub" }.merge(env))
    out
  end

  # NOT named `run` — Minitest::Test#run is the method the runner calls on each
  # test instance, and a private helper of that name replaces it. The whole file
  # then dies with "private method `run' called", which reads like a Ruby
  # version problem rather than a name collision.
  def drive(snippet, op:, op_status: 0, jq: true, env: {})
    Dir.mktmpdir("ecosystem-build-guard") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)

      write_stub(stub, "op", op, op_status) unless op.nil?
      link_real(stub, "jq") if jq
      write_stub(stub, "heroku", "", 1)
      # `grep` is not under test and is not on this PATH, so it is linked in for
      # the benefit of MUTANTS. Without it, restoring the historical
      # `op vault list | grep -qw agents` fails with 127 instead of answering
      # wrong — every test goes red for the wrong reason, and the mutation stops
      # being evidence that the exact-match rule is what holds the line.
      link_real(stub, "grep")

      # PATH is REPLACED, not prepended, and holds ONLY the stub directory. Two
      # reasons, and both were measured: bin/ecosystem-build exports a PATH of
      # its own at load, which would otherwise put the machine's real `op` ahead
      # of this stub and quietly test the operator's live 1Password account; and
      # `jq` ships at /usr/bin/jq on macOS 15, so the only way to ask "what does
      # the guard do when jq is missing?" is to keep /usr/bin out of PATH.
      script = <<~BASH
        source "#{SCRIPT}"
        PATH="#{stub}"
        #{snippet}
        echo "EXIT=$?"
      BASH

      # HOME and PROJECTS_DIR point at the empty tmpdir so sourcing the script
      # neither reads the operator's ~/.zprofile nor finds a satellites.yml.
      base = { "HOME" => tmp, "PROJECTS_DIR" => tmp,
               "MCR_OP_VAULT_AGENT" => nil, "OP_SERVICE_ACCOUNT_TOKEN" => nil,
               "HEROKU_API_KEY" => nil }
      out, = Open3.capture2e(base.merge(env), "bash", "-c", script)
      code = out[/EXIT=(\d+)/, 1]

      assert code, "the harness never reached its EXIT marker — output was:\n#{out}"
      [out, code.to_i]
    end
  end

  # The stub sets its OWN PATH. The harness runs the guard with PATH holding
  # nothing but this directory — which is what makes "op is not installed" and
  # "jq is not installed" real rather than pretended — and a stub that reached
  # for `cat` through that PATH would silently print nothing and be
  # indistinguishable from an empty listing. It was, for one run: every negative
  # test passed and every positive one failed, which is the shape of a harness
  # that proves nothing.
  def write_stub(dir, name, stdout, status)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\nPATH=/usr/bin:/bin\ncat <<'STUB_EOF'\n#{stdout}\nSTUB_EOF\nexit #{status}\n")
    FileUtils.chmod(0o755, path)
  end

  # jq is the tool under test's collaborator, not something to fake — the guard's
  # correctness IS its jq filter. Symlink the real one in.
  def link_real(dir, name)
    # `sh -c`, NOT a bare backtick. `command` is a shell BUILTIN, and Ruby execs
    # directly when a backtick string carries no shell metacharacters — so
    # `command -v jq` raises Errno::ENOENT looking for a binary named `command`.
    # It survived locally by accident of environment and errored 14 tests in CI.
    real = `sh -c 'command -v #{name}'`.strip
    skip "#{name} is not installed; it is a declared brew dep of this ecosystem" if real.empty?
    FileUtils.ln_s(real, File.join(dir, name))
  end
end
