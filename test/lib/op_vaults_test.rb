# frozen_string_literal: true

# [unit] OpVaults — the ONE place that maps a credential lane to its 1Password
# vault and service-account token.
#
# THE DEFECT THIS EXISTS TO PREVENT (2026-08-28). The vault name "agents" was
# hardcoded in eleven places across six files. When the operator switched to a
# 1Password SERVICE_ACCOUNT — which sees only the vaults granted to it — every
# lane lost GitHub auth at once, and the two obvious fixes would have left nine
# call sites broken, including bin/task.
#
# THE SHARPER DEFECT, and why `test_a_build_lane_cannot_reach_admin_credentials`
# is the most important test in this file: `studio-agents` holds the AGENT app
# item but not the DEPLOYER one. Repointing everything at the reachable vault
# turns the build lane green immediately and breaks PRODUCTION DEPLOYS hours
# later. The lanes must resolve to DIFFERENT vaults, and the admin lane must be
# unreadable without its own token.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/op_vaults"

class OpVaultsTest < Minitest::Test
  def setup
    @saved = ENV.to_h.slice("MCR_OP_VAULT_AGENT", "MCR_OP_VAULT_ADMIN",
                            "OP_SERVICE_ACCOUNT_TOKEN", "OP_ADMIN_SERVICE_ACCOUNT_TOKEN")
    %w[MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN
       OP_SERVICE_ACCOUNT_TOKEN OP_ADMIN_SERVICE_ACCOUNT_TOKEN].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  def test_the_two_lanes_resolve_to_different_vaults
    refute_equal OpVaults.vault(:agent), OpVaults.vault(:deployer),
                 "agent and deployer MUST NOT share a vault — studio-agents carries the " \
                 "agent app item and not the deployer's, so collapsing them turns the " \
                 "build lane green while breaking production deploys silently"
  end

  def test_each_lane_reads_its_own_token_variable
    refute_equal OpVaults.token_env(:agent), OpVaults.token_env(:deployer),
                 "a shared token variable would defeat the isolation entirely"
  end

  # THE ISOLATION ITSELF. `op` takes its credential from OP_SERVICE_ACCOUNT_TOKEN
  # and nothing else, so an admin read is only possible when op_env REPLACES it.
  # In an ordinary agent shell the admin token is absent, op_env is empty, and
  # the read proceeds with the agent token — which cannot see the admin vault.
  # That failure IS the feature.
  def test_a_build_lane_cannot_reach_admin_credentials
    ENV["OP_SERVICE_ACCOUNT_TOKEN"] = "ops_agent_token"
    ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")

    assert_nil OpVaults.token(:deployer),
               "an agent shell must not carry the admin token"
    assert_empty OpVaults.op_env(:deployer),
                 "with no admin token, op_env must NOT override OP_SERVICE_ACCOUNT_TOKEN — " \
                 "silently substituting the agent token would hand a build lane the admin " \
                 "vault the moment that vault were ever granted to it"
  end

  def test_the_admin_token_replaces_the_op_credential_when_present
    ENV["OP_SERVICE_ACCOUNT_TOKEN"] = "ops_agent_token"
    ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = "ops_admin_token"

    assert_equal({ "OP_SERVICE_ACCOUNT_TOKEN" => "ops_admin_token" },
                 OpVaults.op_env(:deployer),
                 "op reads only OP_SERVICE_ACCOUNT_TOKEN, so the admin lane must replace it")
    assert_empty OpVaults.op_env(:agent),
                 "the default lane must not rewrite the ambient token"
  end

  def test_an_override_redirects_a_lane_without_forking_the_scripts
    ENV["MCR_OP_VAULT_AGENT"] = "some-other-vault"

    assert_equal "some-other-vault", OpVaults.vault(:agent)
    assert_equal "op://some-other-vault/Item/field", OpVaults.ref("Item", "field", :agent)
  end

  def test_an_unknown_lane_raises_rather_than_defaulting
    error = assert_raises(ArgumentError) { OpVaults.vault(:nope) }

    assert_match(/unknown 1Password lane/, error.message,
                 "a typo'd lane must fail loudly — quietly falling back to the agent " \
                 "vault is how an admin credential ends up read by a build lane")
  end

  def test_the_diagnosis_names_the_missing_token_not_a_bare_read_failure
    ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")

    assert_match(/OP_ADMIN_SERVICE_ACCOUNT_TOKEN/, OpVaults.diagnose(:deployer),
                 "a missing token and a wrong vault need opposite responses, so the " \
                 "message must distinguish them")
  end

  # ── THE REFUSAL MUST NAME A COMMAND THAT WORKS ──────────────────────────────
  #
  # MEASURED 2026-08-30. The old message had ONE branch for a missing admin token:
  # "Run this from the admin lane, or install the token with
  # bin/setup-1pass-token --admin." Both halves failed the reader. The first names
  # NO command — the answer is `source ~/.zprofile.admin`, and this file was the
  # only place in the repo that mentioned that path at all. The second is an
  # INSTALL, which prompts for a credential the operator must fetch by hand.
  #
  # WHAT IT COST: an agent read that refusal, concluded the deployer lane was not
  # self-service, and asked Mr. McRitchie to hand-mint deployer tokens from a
  # downloaded .pem — repeatedly, blocking a production deploy on him. The token
  # had been at ~/.zprofile.admin since 2026-08-28; sourcing it worked first try.
  #
  # THE ASSERTION THAT MATTERS IS THE DIFFERENCE. A single-branch message passes
  # any test that merely checks "it mentions the admin token" — which is precisely
  # how the old one survived. So these compare the two states against each other.

  def test_a_provisioned_machine_is_told_to_source_the_file
    message = with_provisioned(true) { OpVaults.diagnose(:deployer) }

    assert_includes message, "source ~/.zprofile.admin",
                     "the remedy must name the COMMAND, not merely the lane"
    refute_includes message, "bin/setup-1pass-token",
                     "installing is the wrong errand on a machine already provisioned — " \
                     "it asks the operator for a credential they already supplied"
  end

  def test_an_unprovisioned_machine_is_told_to_install_once
    message = with_provisioned(false) { OpVaults.diagnose(:deployer) }

    assert_includes message, "bin/setup-1pass-token --admin",
                     "with no token file this genuinely IS the operator's step"
    refute_includes message, "source ~/.zprofile.admin",
                     "sourcing a file that does not exist is a dead end"
  end

  # THE GUARD AGAINST THE ORIGINAL DEFECT, stated as the property rather than as
  # two example strings: the two states must not produce the same advice. If a
  # future edit collapses the branches, this fails even if both strings change.
  def test_the_two_states_give_different_remedies
    provisioned = with_provisioned(true)  { OpVaults.diagnose(:deployer) }
    fresh       = with_provisioned(false) { OpVaults.diagnose(:deployer) }

    refute_equal provisioned, fresh,
                 "one message for both states is the defect this test exists to catch — " \
                 "the causes need opposite responses, one self-service and one the operator's"
  end

  # The agent lane's diagnosis must not be dragged into the ADMIN branch — the two
  # lanes have different token files and different install commands.
  # DRIVE THE BRANCH. Called bare, this asserted against the VAULT-visibility
  # message — the agent lane's token is set in the suite's own environment, so the
  # token-absent branch was never reached and mutating the install command to the
  # admin one survived. Both states are forced here instead.
  def test_the_agent_lane_is_not_given_admin_advice
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
    [true, false].each do |provisioned|
      message = with_provisioned(provisioned) { OpVaults.diagnose(:agent) }

      refute_includes message, "zprofile.admin",
                      "provisioned=#{provisioned}: the agent lane has its own profile"
      refute_includes message, "--admin",
                      "provisioned=#{provisioned}: --admin installs the ADMIN token; " \
                      "handing it to an agent shell prescribes the wrong credential " \
                      "and prompts the operator for one they need not supply"
    end
  end

  # ── THE SAME DEFECT, ONE RUNG DOWN ──────────────────────────────────────────
  #
  # `diagnose` used to bail to the vault-visibility hint for the DEFAULT lane, so
  # an agent shell with no OP_SERVICE_ACCOUNT_TOKEN was told to "check
  # `op vault list`" — a command that authenticates with the very token it is
  # missing, and therefore cannot work. That is the bug class this file's other
  # tests exist for, sitting unnoticed in the same method.
  #
  # It also made the agent lane's `profile:` key DEAD DATA: a reviewer mutated it
  # to garbage on 2026-08-30 and killed zero tests across all three suites. These
  # tests are what make that key load-bearing.

  def test_a_provisioned_agent_shell_is_told_to_source_its_profile
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
    message = with_provisioned(true) { OpVaults.diagnose(:agent) }

    assert_includes message, "source ~/.zprofile",
                    "an agent shell that never sourced its profile has a self-service fix"
    refute_includes message, "op vault list",
                    "naming a command that needs the MISSING token is the whole defect: " \
                    "`op` authenticates with OP_SERVICE_ACCOUNT_TOKEN, so it cannot run here"
  end

  def test_an_unprovisioned_agent_machine_is_told_to_install_the_agent_token
    ENV.delete("OP_SERVICE_ACCOUNT_TOKEN")
    message = with_provisioned(false) { OpVaults.diagnose(:agent) }

    assert_includes message, "bin/setup-1pass-token",
                    "with no ~/.zprofile there is genuinely nothing to source"
    refute_includes message, "source ~/.zprofile",
                    "sourcing a file that does not exist is a dead end"
  end

  # THE PROPERTY, per lane: the two machine states must never give the SAME advice,
  # because they need opposite responses. Asserted for BOTH lanes — the deployer
  # version of this passed for months while the agent lane had no branch at all.
  def test_both_lanes_distinguish_the_two_machine_states
    %i[agent deployer].each do |lane|
      ENV.delete(OpVaults.token_env(lane))
      provisioned = with_provisioned(true)  { OpVaults.diagnose(lane) }
      fresh       = with_provisioned(false) { OpVaults.diagnose(lane) }

      refute_equal provisioned, fresh,
                   "the #{lane} lane gives one message for both machine states"
    end
  end

  # A LANE'S PROFILE PATH IS LOAD-BEARING, not decoration. If `profile:` is ever
  # dropped or mistyped, the remedy stops naming the file the operator must source
  # and this fails. Mutating either LANES entry breaks it.
  def test_each_lane_names_its_own_profile_in_its_remedy
    { agent: "~/.zprofile", deployer: "~/.zprofile.admin" }.each do |lane, path|
      ENV.delete(OpVaults.token_env(lane))
      message = with_provisioned(true) { OpVaults.diagnose(lane) }

      assert_includes message, "source #{path}",
                      "the #{lane} remedy must name the file that carries ITS token"
    end
  end

  # ── THE REMEDY MUST BE PASTEABLE, NOT MERELY PRESENT ────────────────────────
  #
  # Every branch that offers a command block indents it and puts it LAST, so the
  # operator can select the tail of the message and run it. `bin/gh-token` used to
  # append "(is `op` signed in?)" AFTER this, landing it on the same line as
  # `bin/setup-1pass-token --admin` — a shell syntax error when pasted. Asserting
  # only that the command "is included" passes on that contaminated line, which is
  # how it survived.
  def test_a_remedy_block_is_the_last_thing_in_the_message
    %i[agent deployer].each do |lane|
      ENV.delete(OpVaults.token_env(lane))
      [true, false].each do |provisioned|
        message = with_provisioned(provisioned) { OpVaults.diagnose(lane) }
        indented = message.lines.select { |l| l.start_with?("    ") }

        refute_empty indented, "#{lane}/#{provisioned}: the remedy must be an indented command"
        assert_equal indented.last.rstrip, message.lines.last.rstrip,
                     "#{lane}/#{provisioned}: the message must END on the command — " \
                     "anything appended lands on that line and breaks the paste"
        indented.each do |line|
          refute_match(/[()]/, line,
                       "#{lane}/#{provisioned}: #{line.strip.inspect} carries prose " \
                       "punctuation; pasting it is a shell syntax error")
        end
      end
    end
  end

  # DETERMINISTIC ON BOTH KINDS OF MACHINE. An earlier version of this test read
  # `File.exist?("~/.zprofile.admin")` and compared it to provisioned? — which on a
  # PROVISIONED machine is `true == true` and cannot fail. Mutating provisioned? to
  # `true` survived it. So the file's presence is driven here rather than observed:
  # each state is asserted against a path this test controls.
  def test_provisioned_follows_the_token_file_not_the_machine
    Dir.mktmpdir do |dir|
      present = File.join(dir, "zprofile.admin")
      File.write(present, "# token would be here\n")

      assert with_profile_path(present) { OpVaults.provisioned?(:deployer) },
             "a lane whose token file EXISTS is provisioned"
      refute with_profile_path(File.join(dir, "definitely-absent")) { OpVaults.provisioned?(:deployer) },
             "a lane whose token file is ABSENT is not — telling that machine to " \
             "`source` it would be a dead end"
    end
  end

  def test_the_deployer_profile_is_the_admin_one
    assert OpVaults.profile_path(:deployer).end_with?(".zprofile.admin")
  end

  private

  # Drive the branch WITHOUT touching the real filesystem or the real home dir —
  # both states must be testable on any machine, including the provisioned one
  # this runs on, or half these assertions would be unreachable in practice.
  def with_profile_path(path)
    OpVaults.singleton_class.send(:alias_method, :real_profile_path, :profile_path)
    OpVaults.define_singleton_method(:profile_path) { |_ = nil| path }
    yield
  ensure
    OpVaults.singleton_class.send(:remove_method, :profile_path)
    OpVaults.singleton_class.send(:alias_method, :profile_path, :real_profile_path)
    OpVaults.singleton_class.send(:remove_method, :real_profile_path)
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
