# frozen_string_literal: true

# DomainRegister — buy a domain for one of OUR OWN entities on Cloudflare
# Registrar, by API (bin/domain-register). The runbook is Steffon's
# domain-purchase SOP, § Cloudflare Registrar (our own entities). A client's
# domain never goes on Cloudflare Registrar; that rule lives in the same SOP.
#
# It spends money on Alex McRitchie's card, so register refuses unless, re-checked
# immediately before the POST:
#   - the domain is registrable,
#   - the registration price equals --price EXACTLY (USD),
#   - a premium domain carries --premium (and Cloudflare's API registers no
#     premium domain today, so even then it stops: see Runner::PREMIUM_VIA_API),
#   - --ok carries Alex McRitchie's own words with the date (YYYY-MM-DD),
#   - the ledger holds no open authorization for the domain, and
#   - Cloudflare's registration-status answers its documented "No workflow
#     found" (any workflow, or any other answer, refuses).
# A purchase request that gets no clear answer (no reply, or a 5xx) is ledgered
# `unknown`, never `failed`: money MAY have moved, and a re-run refuses.
# It registers with auto_renew true and privacy_mode redaction, polls the
# registration-status workflow to a terminal state, writes the ledger, and then
# proves the zone exists in our Cloudflare account (same token, zone read).
#
# Plain Ruby, no Rails. The HTTP seam, Abort, Write and #redact are
# DomainCutover's (bin/lib/domain_cutover/http.rb); the zone proof reuses its
# Cloudflare v4 client, so there is one Cloudflare client, not two.
#
# Tests: test/lib/domain_register_test.rb ([unit]) and
# test/lib/domain_register_integration_test.rb ([integration], a stubbed API).

require_relative "domain_cutover"

module DomainRegister
  Abort = DomainCutover::Abort
end

require_relative "domain_register/quote"
require_relative "domain_register/registrar"
require_relative "domain_register/ledger"
require_relative "domain_register/runner"

module DomainRegister
  DOMAIN = /\A(?!www\.)(?!-)[a-z0-9-]+(\.[a-z0-9-]+)+\z/

  module_function

  def redact(text, secrets) = DomainCutover.redact(text, secrets)

  # Credentials, read from 1Password by item name in the ADMIN lane
  # (studio-agents-admin; source ~/.zprofile.admin), never printed.
  #
  # One token for everything: cloudflare.studio.provision (api-token +
  # account-id). Alex McRitchie widened it on 2026-10-19 with Account > Registrar > Edit
  # rather than file a separate Registrar-only token, so the same value now
  # checks domains, BUYS them (the registration POST charges the account's
  # default card), and reads the new zone back. It is a cost-bearing credential.
  # Before the widening it answered domain-check with "10000 Authentication
  # error"; that answer now means the Registrar grant is missing again.
  module Credentials
    ITEM = DomainCutover::Credentials::CLOUDFLARE_ITEM

    module_function

    def cloudflare(reader = method(:op_read))
      require_relative "op_vaults"
      raise Abort, "cannot read #{ITEM}: #{OpVaults.diagnose(:deployer)}" unless OpVaults.token(:deployer)

      env = OpVaults.op_env(:deployer)
      token = reader.call(OpVaults.ref(ITEM, "api-token", :deployer), env)
      raise Abort, "#{ITEM} api-token read empty: stop. Nothing ran." if token.empty?

      account = reader.call(OpVaults.ref(ITEM, "account-id", :deployer), env)
      raise Abort, "#{ITEM} account-id read empty: stop. Nothing ran." if account.empty?

      [token, account]
    end

    # `op read`, value on stdout only, stderr dropped so nothing echoes. A failed
    # read (an expired or wrong admin token, a missing item) raises, so it is
    # never mistaken for an item that exists but is empty.
    # The default runner is bounded and metered (OpMeter.popen), like every op read
    # under bin/; a killed read leaves a failed `$?`, which raises below.
    def op_read(ref, env, runner: ->(e, argv) { [OpMeter.popen(e, argv, via: "domain_register", err: File::NULL).to_s, $?] })
      require_relative "op_meter"
      out, status = runner.call(env, ["op", "read", ref])
      unless status&.success?
        require_relative "op_vaults"
        raise Abort, "op read #{ref} failed (exit #{status&.exitstatus.inspect}): #{OpVaults.diagnose(:deployer)} Nothing ran."
      end

      out.strip
    rescue Errno::ENOENT
      raise Abort, "the 1Password CLI (op) is not on PATH. Nothing ran."
    end
  end
end
