# frozen_string_literal: true

# DomainCutover — the Pro-tier move of a domain's DNS to Cloudflare, as one
# command (bin/domain-cutover). The runbook is Steffon's domain-dns SOP,
# § Cloudflare DNS — Pro and above; the reasons behind each guard are in
# DomainCutover::Runner and were measured on the 2026-10-13 moves of
# commercialwelding.llc and mcritchie.industries.
#
# Plain Ruby, no Rails, and no bash: macOS ships bash 3.2.
#
# Unit and integration tests: test/lib/domain_cutover_test.rb and
# test/lib/domain_cutover_integration_test.rb (every HTTP call faked).

require_relative "domain_cutover/http"
require_relative "domain_cutover/records"
require_relative "domain_cutover/doh"
require_relative "domain_cutover/rdap"
require_relative "domain_cutover/cloudflare"
require_relative "domain_cutover/heroku"
require_relative "domain_cutover/guide"
require_relative "domain_cutover/workspace"
require_relative "domain_cutover/state"
require_relative "domain_cutover/runner"

module DomainCutover
  # Credentials, read from 1Password by item name and never printed.
  #   Cloudflare: cloudflare.studio.provision (studio-agents-admin, the admin
  #               lane): api-token + account-id.
  #   Heroku:     HEROKU_API_KEY when the shell has it, else heroku.studio.agents
  #               (studio-agents, the agent lane): credential.
  module Credentials
    CLOUDFLARE_ITEM = "cloudflare.studio.provision"
    HEROKU_ITEM = "heroku.studio.agents"

    module_function

    def cloudflare(reader = method(:op_read))
      require_relative "op_vaults"
      unless OpVaults.token(:deployer)
        raise Abort, "cannot read #{CLOUDFLARE_ITEM}: #{OpVaults.diagnose(:deployer)}"
      end

      token = reader.call(OpVaults.ref(CLOUDFLARE_ITEM, "api-token", :deployer), OpVaults.op_env(:deployer))
      account = reader.call(OpVaults.ref(CLOUDFLARE_ITEM, "account-id", :deployer), OpVaults.op_env(:deployer))
      raise Abort, "#{CLOUDFLARE_ITEM} read empty: stop. Nothing ran." if token.empty? || account.empty?

      [token, account]
    end

    def heroku(reader = method(:op_read), env: ENV)
      key = env["HEROKU_API_KEY"].to_s.strip
      return key unless key.empty?

      require_relative "op_vaults"
      key = reader.call(OpVaults.ref(HEROKU_ITEM, "credential"), OpVaults.op_env)
      raise Abort, "no HEROKU_API_KEY and #{HEROKU_ITEM} read empty: stop. Nothing ran." if key.empty?

      key
    end

    # `op read`, value on stdout only; stderr dropped so nothing echoes.
    #
    # BOUNDED AND METERED through OpMeter.popen (20 seconds an attempt, one retry
    # past the cache daemon, then SIGKILL). This is the read `bin/release` makes for
    # a static_cloudflare deploy (StaticCloudflare::Credentials.r2), and it was the
    # last bare IO.popen on the release path: from 06:14 to 08:17 MDT on 2026-10-27
    # every `op` call hung, and an unbounded read here would have frozen the ship
    # rather than failed it. A timed-out read returns "", which every caller
    # already refuses as an empty item.
    def op_read(ref, env)
      require_relative "op_meter"
      OpMeter.popen(env, ["op", "read", ref], via: "domain_cutover", err: File::NULL).to_s.strip
    rescue Errno::ENOENT
      raise Abort, "the 1Password CLI (op) is not on PATH"
    end
  end
end
