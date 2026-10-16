# frozen_string_literal: true

require "yaml"

module AgentMailbox
  # WHO an answer is speaking with, and what that lets it do
  # (docs/agents/modules/agent-communication.md). The board resolves the audience
  # from the verified sender's person (AgentPerson#audience) and sends it in the
  # context bundle; the worker reads it here. Nothing in a message, a display name
  # or a note can set it, and anything missing or malformed is `public`: the
  # audience fails closed.
  #
  # The board's model requires this file too, so ROLES is the one list of roles.
  class Audience
    ROLES = %w[owner team client public].freeze
    FALLBACK = "public"
    # What a client domain may look like: a key of config/agent_domains.yml. It is
    # printed outside the untrusted fence, so it must stay code-shaped.
    DOMAIN = /\A[a-z0-9_]{1,40}\z/
    SOP_PATH = "docs/agents/modules/agent-communication.md"

    # THE GATE. Every capability an answer may use, and the roles that may use
    # it. A new action adds a row here and asks `may?`; a capability with no row
    # is refused.
    CAPABILITIES = {
      read_action: %w[owner team],      # the soul's one read-only action (Responder::ACTIONS)
      internal_context: %w[owner team], # the role doc, and DOMAIN docs marked internal: true
      # Domain-agent proposals (docs/agents/system/agent-message-loop.md, "Proposals
      # and confirm"). REQUESTING is these rows AND the capability's own
      # min_audience in config/agent_domains.yml (meets?); a client may request a
      # change only in its own client_domain (AgentMailbox::DomainRegistry).
      propose_ask: %w[owner team client],
      propose_change: %w[owner team client],
      propose_operate: %w[owner team],
      # CONFIRMING (`go`, `no`, `change: …` on an open proposal) is the owner's alone.
      confirm_proposal: %w[owner]
    }.freeze
    # The ranking a capability's min_audience is read against, lowest first.
    RANK = %w[public client team owner].freeze

    class RulesMissing < StandardError; end

    attr_reader :role, :client_domain

    def initialize(role:, client_domain: nil)
      @role = ROLES.include?(role.to_s) ? role.to_s : FALLBACK
      domain = client_domain.to_s
      @client_domain = @role == "client" && domain.match?(DOMAIN) ? domain : nil
      # A client with no usable domain cannot be scoped to one, so it is public.
      @role = FALLBACK if @role == "client" && @client_domain.nil?
    end

    # The bundle's `audience` ({"role" => …, "client_domain" => …}), or public
    # when the bundle has none (a dry run, or a board predating audiences).
    def self.from_context(context)
      data = context.is_a?(Hash) ? context["audience"] : nil
      return new(role: FALLBACK) unless data.is_a?(Hash)

      new(role: data["role"], client_domain: data["client_domain"])
    end

    def may?(capability)
      CAPABILITIES.fetch(capability.to_sym, []).include?(@role)
    end

    def internal? = may?(:internal_context)

    # Does this audience reach `min` on RANK? false for a min RANK does not name.
    def meets?(min)
      need = RANK.index(min.to_s)
      !need.nil? && RANK.index(@role).to_i >= need
    end

    def owner? = @role == "owner"

    # "owner", "team", "client (turf_monster)", "public": code-shaped, printed
    # outside the fence.
    def label = @client_domain ? "#{@role} (#{@client_domain})" : @role

    # The rules this audience is held to, as the prompt prints them: the
    # always-rules, then ONLY this audience's who / may / never. `domain_name`
    # fills a client's "{domain}". Raises RulesMissing when the SOP or its block
    # cannot be read: an answer must not go out with no rules.
    def rules_text(repo_root:, domain_name: nil)
      rules = self.class.rules(repo_root)
      mine = rules.fetch("audiences").fetch(@role)
      who = mine["who"].to_s.gsub("{domain}", domain_name.to_s.strip.empty? ? @client_domain.to_s : domain_name.to_s)
      lines = [ "Who: #{who}", "", "Always, with everyone:" ]
      lines += Array(rules["always"]).map { |r| "- #{r}" }
      lines += [ "", "You may discuss:" ] + bullets(mine["may"])
      lines += [ "", "Never, with this audience:" ] + bullets(mine["never"])
      lines.join("\n")
    end

    # The SOP's front matter, checked: every role present, each with lists.
    def self.rules(repo_root)
      path = File.join(repo_root, SOP_PATH)
      raise RulesMissing, "#{SOP_PATH} is missing" unless File.file?(path)

      text = File.read(path, encoding: "UTF-8").scrub
      block = text[/\A---\n(.*?)\n---\n/m, 1]
      raise RulesMissing, "#{SOP_PATH} has no rules block" unless block

      data = YAML.safe_load(block, aliases: false)
      audiences = data.is_a?(Hash) ? data["audiences"] : nil
      missing = audiences.is_a?(Hash) ? ROLES - audiences.keys : ROLES
      raise RulesMissing, "#{SOP_PATH} has no rules for #{missing.join(', ')}" if missing.any?

      data
    rescue Psych::Exception => e
      raise RulesMissing, "#{SOP_PATH} rules block does not parse: #{e.message}"
    end

    def ==(other) = other.is_a?(Audience) && other.role == role && other.client_domain == client_domain

    def to_h = { "role" => role, "client_domain" => client_domain }

    private

    def bullets(list)
      items = Array(list).map(&:to_s).reject(&:empty?)
      items.empty? ? [ "- (nothing beyond the always-rules)" ] : items.map { |r| "- #{r}" }
    end
  end
end
