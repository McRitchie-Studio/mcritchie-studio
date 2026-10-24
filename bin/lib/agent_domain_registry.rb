# frozen_string_literal: true

require "yaml"
require_relative "agent_audience"

module AgentMailbox
  # config/agent_domains.yml read as the DOMAIN REGISTRY
  # (docs/agents/system/agent-message-loop.md, "Proposals and confirm"): each
  # domain's front-door soul, and the catalog of what that soul may propose.
  #
  # PURE: no Rails, no database. The board (AgentProposal, AgentMessages::MemoryBundle)
  # and the worker read the same file through this one class, so the catalog a
  # prompt shows and the catalog a proposal is validated against cannot differ.
  #
  # ONE SOUL, ONE CATALOG. Only a domain's `soul` (its front door) has a
  # catalog. Another soul mapped to the domain under `souls:` gets the domain's
  # doc and nothing it can propose. A proposal is checked against the
  # proposing soul's OWN domain, so Avi cannot propose a Turf query (and Ritch,
  # mapped to a domain with no catalog, proposes nothing).
  #
  # THE AUDIENCE GATE is AgentMailbox::Audience (bin/lib/agent_audience.rb):
  # requesting a kind needs Audience#may?(:propose_<kind>) AND the capability's
  # min_audience on Audience::RANK (#meets?), and a client may request only in
  # the domain it is a client of. `audience` is always an Audience the board
  # resolved from the sender's person, never anything a message says.
  #
  # FAIL CLOSED. An unreadable file, a missing min_audience, or a schema the
  # class does not understand refuses the proposal; nothing here guesses.
  class DomainRegistry
    PATH = File.expand_path("../../config/agent_domains.yml", __dir__)
    SHAPES_PATH = File.expand_path("../../config/feature_shapes.yml", __dir__)
    KINDS = %w[ask operate change].freeze
    # A change proposal's params, fixed in code: the task template the board
    # fills (title, kind, shape, accept, test, risk). The domain supplies only
    # the repo and the default shape.
    TASK_KINDS = %w[feature bug chore].freeze
    TITLE_MAX = 80
    LINE_MAX = 200
    LIST_MAX = 5
    SUMMARY_MAX = 200
    NAME = /\A[a-z][a-z0-9_]{0,40}\z/

    # ok: true with the normalized proposal, or ok: false with the reason.
    Verdict = Struct.new(:ok, :reason, :proposal, keyword_init: true) do
      def ok? = ok == true
    end

    def self.load(path = PATH, shapes_path: SHAPES_PATH)
      config = File.file?(path) ? (YAML.safe_load_file(path, aliases: false) || {}) : {}
      shapes = File.file?(shapes_path) ? ((YAML.safe_load_file(shapes_path, aliases: true) || {})["shapes"] || {}).keys : []
      new(config, shapes: shapes)
    rescue Psych::Exception
      new({}, shapes: [])
    end

    attr_reader :shapes

    def initialize(config, shapes: [])
      @config = config.is_a?(Hash) ? config : {}
      @shapes = shapes.map(&:to_s)
    end

    def domains = (@config["domains"].is_a?(Hash) ? @config["domains"] : {})

    # The domain key a soul answers for (its DOMAIN layer), or nil.
    def domain_key_for(soul) = soul_domains[soul.to_s]

    # The `souls:` map, soul => domain key.
    def soul_domains = (@config["souls"].is_a?(Hash) ? @config["souls"] : {})

    # The domain whose FRONT DOOR is this soul, or nil.
    def front_door(soul)
      key, domain = domains.find { |_, d| d.is_a?(Hash) && d["soul"].to_s == soul.to_s && !soul.to_s.empty? }
      key ? domain.merge("key" => key) : nil
    end

    def reply_name(soul) = front_door(soul)&.dig("reply_name").to_s.strip.then { |n| n.empty? ? nil : n }

    # WARM SESSIONS (docs/agents/system/agent-message-loop.md, "Warm sessions").
    # A domain opts in with `warm_session: true`; absent or anything else is off,
    # and off is today's one-run-per-message path. Only the domain's FRONT-DOOR
    # soul answers from the warm session: another soul mapped to the domain keeps
    # one run per message, so one session never speaks as two souls.
    CONSOLIDATE_AT = 150_000
    CONSOLIDATE_RANGE = (10_000..1_000_000)

    def warm_session?(domain)
      entry = domains[domain.to_s]
      entry.is_a?(Hash) && entry["warm_session"] == true
    end

    # The warm domain this soul is the front door of, or nil.
    def warm_domain_for(soul)
      door = front_door(soul)
      door && door["warm_session"] == true ? door["key"] : nil
    end

    # The context size (input + cache read + cache write tokens of one turn)
    # past which the holder consolidates: the domain's `consolidate_at` when it
    # is an integer in CONSOLIDATE_RANGE, else CONSOLIDATE_AT.
    def consolidate_at(domain)
      entry = domains[domain.to_s]
      value = entry.is_a?(Hash) ? entry["consolidate_at"] : nil
      value.is_a?(Integer) && CONSOLIDATE_RANGE.cover?(value) ? value : CONSOLIDATE_AT
    end

    # May this audience REQUEST a capability of `kind` with this min_audience in
    # this domain? The Audience rows, the min_audience, and a client's own domain.
    def allows?(audience, kind, min, domain)
      return false unless audience.is_a?(Audience)
      return false unless audience.may?(:"propose_#{kind}") && audience.meets?(min)

      audience.role != "client" || audience.client_domain == domain["key"]
    end

    # What this soul may propose to a sender of `audience`, as the prompt lists
    # it: [{ "kind", "capability", "description", "params" }]. Empty for a soul
    # that is no domain's front door.
    def catalog(soul, audience:)
      domain = front_door(soul)
      return [] unless domain

      caps = domain["capabilities"] || {}
      entries = (caps["ask"] || {}).filter_map do |name, spec|
        next unless spec.is_a?(Hash) && allows?(audience, "ask", spec["min_audience"], domain)

        { "kind" => "ask", "capability" => name.to_s, "description" => spec["description"].to_s,
          "params" => describe_params(spec["params"] || {}) }
      end
      change = caps["change"]
      if change.is_a?(Hash) && allows?(audience, "change", change["min_audience"], domain)
        entries << { "kind" => "change", "capability" => "task",
                     "description" => "Open a board task in #{change['repo']} for new code (a feature, a fix, a chore).",
                     "params" => describe_params(change_schema(change)) }
      end
      entries
    end

    # The board's check of a parsed PROPOSAL block (a Hash from ProposalBlock).
    # Refused unless the capability is in THIS soul's own domain, the sender's
    # audience meets its min_audience, and every param fits its schema.
    def validate(soul:, audience:, proposal:)
      return refuse("not a JSON object") unless proposal.is_a?(Hash)

      domain = front_door(soul)
      return refuse("#{soul} is no domain's front door") unless domain
      return refuse("no audience") unless audience.is_a?(Audience)

      kind = proposal["kind"].to_s
      name = proposal["capability"].to_s
      return refuse("unknown kind #{kind.inspect}") unless KINDS.include?(kind)
      return refuse("bad capability name") unless name.match?(NAME)

      spec, schema = spec_for(domain, kind, name)
      return refuse("#{kind} #{name.inspect} is not in #{domain['key']}'s catalog") unless spec
      unless allows?(audience, kind, spec["min_audience"], domain)
        return refuse("#{audience.label} may not request #{kind} #{name}")
      end

      params, error = check_params(proposal["params"], schema)
      return refuse(error) if error

      summary = plain(proposal["summary"], SUMMARY_MAX)
      summary = "#{kind} #{name}" if summary.empty?
      Verdict.new(ok: true, proposal: { "kind" => kind, "capability" => name, "params" => params,
                                        "summary" => summary, "domain" => domain["key"] })
    end

    # The ask's query name and the domain's app, for the executor.
    def ask(soul, name)
      domain = front_door(soul)
      spec = domain && (domain.dig("capabilities", "ask") || {})[name.to_s]
      spec.is_a?(Hash) ? spec.merge("app" => domain["app"], "domain" => domain["key"]) : nil
    end

    def change(soul)
      domain = front_door(soul)
      spec = domain && domain.dig("capabilities", "change")
      spec.is_a?(Hash) ? spec.merge("domain" => domain["key"]) : nil
    end

    private

    def refuse(reason) = Verdict.new(ok: false, reason: reason)

    def spec_for(domain, kind, name)
      caps = domain["capabilities"] || {}
      case kind
      when "ask"
        spec = (caps["ask"] || {})[name]
        spec.is_a?(Hash) ? [ spec, spec["params"] || {} ] : nil
      when "change"
        spec = caps["change"]
        name == "task" && spec.is_a?(Hash) ? [ spec, change_schema(spec) ] : nil
      when "operate"
        spec = (caps["operate"] || {})[name]
        spec.is_a?(Hash) ? [ spec, spec["params"] || {} ] : nil
      end
    end

    def change_schema(spec)
      shapes = @shapes.empty? ? [ spec["default_shape"].to_s ] : @shapes
      {
        "title" => { "type" => "string", "max" => TITLE_MAX, "required" => true },
        "kind" => { "type" => "enum", "values" => TASK_KINDS, "default" => "feature" },
        "shape" => { "type" => "enum", "values" => shapes, "default" => spec["default_shape"].to_s },
        "accept" => { "type" => "list", "max_items" => LIST_MAX, "max" => LINE_MAX, "required" => true },
        "test" => { "type" => "list", "max_items" => LIST_MAX, "max" => LINE_MAX, "required" => true },
        "risk" => { "type" => "list", "max_items" => LIST_MAX, "max" => 40 }
      }
    end

    # [normalized params, nil] or [nil, reason]. Unknown keys are refused, not
    # dropped: a model that invents a param is told so in the log.
    def check_params(raw, schema)
      raw = {} if raw.nil?
      return [ nil, "params must be an object" ] unless raw.is_a?(Hash)
      return [ nil, "params schema is not a mapping" ] unless schema.is_a?(Hash)

      extra = raw.keys.map(&:to_s) - schema.keys.map(&:to_s)
      return [ nil, "unknown param(s) #{extra.join(', ')}" ] if extra.any?

      out = {}
      schema.each do |key, rule|
        key = key.to_s
        value, error = check_value(key, raw.key?(key) ? raw[key] : raw[key.to_sym], rule || {})
        return [ nil, error ] if error

        out[key] = value unless value.nil?
      end
      [ out, nil ]
    end

    def check_value(key, value, rule)
      if value.nil?
        return [ nil, "#{key} is required" ] if rule["required"]

        return [ rule["default"], nil ]
      end

      case rule["type"].to_s
      when "integer"
        int = value.is_a?(Integer) ? value : (value.is_a?(String) && value.match?(/\A-?\d{1,9}\z/) ? value.to_i : nil)
        return [ nil, "#{key} must be an integer" ] if int.nil?
        return [ nil, "#{key} must be between #{rule['min']} and #{rule['max']}" ] if out_of_range?(int, rule)

        [ int, nil ]
      when "string"
        text = value.is_a?(String) ? plain(value, rule["max"] || LINE_MAX) : nil
        return [ nil, "#{key} must be text" ] if text.nil? || text.empty?

        [ text, nil ]
      when "enum"
        text = value.to_s
        return [ nil, "#{key} must be one of #{Array(rule['values']).join(', ')}" ] unless Array(rule["values"]).include?(text)

        [ text, nil ]
      when "list"
        list = value.is_a?(String) ? [ value ] : value
        return [ nil, "#{key} must be a list of text" ] unless list.is_a?(Array) && list.all? { |v| v.is_a?(String) }

        items = list.map { |v| plain(v, rule["max"] || LINE_MAX) }.reject(&:empty?)
        return [ nil, "#{key} takes at most #{rule['max_items']} items" ] if rule["max_items"] && items.size > rule["max_items"].to_i
        return [ nil, "#{key} is required" ] if rule["required"] && items.empty?

        [ items, nil ]
      else
        [ nil, "#{key} has a schema type this registry does not know" ]
      end
    end

    def out_of_range?(int, rule)
      (rule.key?("min") && int < rule["min"].to_i) || (rule.key?("max") && int > rule["max"].to_i)
    end

    # One line of plain text: control characters and markdown links out,
    # whitespace folded, mentions defanged, cut to `max`.
    def plain(value, max)
      value.to_s.gsub(/[[:cntrl:]]/, " ").gsub(/<@[!&]?\d+>|@(everyone|here)/, "").gsub(/\s+/, " ").strip[0, max.to_i]
    end

    def describe_params(schema)
      schema.to_h do |key, rule|
        rule ||= {}
        text = case rule["type"].to_s
               when "integer" then "integer #{rule['min']}..#{rule['max']}#{rule.key?('default') ? ", default #{rule['default']}" : ''}"
               when "string" then "text, at most #{rule['max']} characters"
               when "enum" then "one of #{Array(rule['values']).join(', ')}#{rule['default'].to_s.empty? ? '' : ", default #{rule['default']}"}"
               when "list" then "list of up to #{rule['max_items']} short lines"
               else rule["type"].to_s
               end
        [ key.to_s, rule["required"] ? "#{text} (required)" : text ]
      end
    end
  end
end
