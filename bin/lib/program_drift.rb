# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"
require "yaml"
require "fileutils"
require "tmpdir"
require "rubygems" # Gem::Version, for comparing x.y.z

# ProgramDrift — is each cluster running the program version its source branch carries?
#
# WHY THIS EXISTS. turf-vault v0.26 merged to main on 2026-10-11 and neither cluster
# was upgraded, because the release lane (bin/release, qa-release, production-deploy)
# ships Heroku apps and never an on-chain program. Nothing compared the program's
# source with the chain, so nothing noticed. This module is that comparison, and
# bin/release status, bin/program-drift and Steffon's heartbeat all print it.
#
# READ-ONLY. It reads a file from GitHub and two accounts over JSON-RPC. It signs
# nothing, holds no key, and writes only its own cache file.
#
# WHAT IT MEASURES, PER CLUSTER:
#   source version   the [package] version in `version_file` on `source_branch`
#   deployed version the deployment doc's Version row for that cluster, BELIEVED only
#                    when the chain's last-deploy slot equals the doc's Deployed slot
#
# The chain does not carry a version number; it carries the slot of the last deploy
# (the ProgramData account's header). The doc maps a slot to a version. So the slot
# match is what makes the doc's Version row a measurement: if anyone has deployed
# since the doc was written, the slots differ and the verdict is UNCONFIRMED. The doc
# alone is never proof, and the chain alone cannot name a version.
#
# FAIL CLOSED. Every unreadable input (GitHub, the doc's rows, the RPC, a slot that
# does not match) yields :unconfirmed, which prints under PROGRAM DRIFT as "cannot
# confirm". Nothing that could not be read is ever reported as current.
module ProgramDrift
  CONFIG_PATH = File.expand_path("../../config/onchain_programs.yml", __dir__)
  UPGRADEABLE_LOADER = "BPFLoaderUpgradeab1e11111111111111111111111"
  # The ProgramData header: u32 enum tag (3 = ProgramData), then the u64 slot.
  PROGRAM_DATA_TAG = 3
  HEADER_BYTES = 12
  # status must stay fast: each RPC call is time-boxed, clusters read in parallel,
  # and a complete reading is cached for CACHE_TTL seconds.
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 6
  CACHE_TTL = 600
  # Test seam: when set, every cluster's RPC goes here instead (OutboundSeams points it
  # at an unroutable address so a sealed suite never reaches a real cluster).
  RPC_OVERRIDE_ENV = "PROGRAM_DRIFT_RPC_URL"
  SOP = "docs/agents/agents/steffon/sops/program-upgrade.md"

  class ReadError < StandardError; end

  Program = Struct.new(:name, :github, :source_branch, :version_file, :deployment_doc,
                       :card_slug, :clusters, keyword_init: true)
  Cluster = Struct.new(:name, :program_id, :rpc_url, :doc_section, keyword_init: true)

  # One cluster's verdict. state is :current, :behind, :ahead or :unconfirmed.
  # card is the board's answer for card_slug: a Hash ({"slug","stage"}), nil (no
  # such card, or only an archived one), or :unknown (the board could not be read).
  Reading = Struct.new(:program, :cluster, :state, :source_version, :deployed_version,
                       :chain_slot, :doc_slot, :reason, :card_slug, :card, keyword_init: true) do
    def drift?
      state != :current
    end

    def to_h
      super.merge(card: card.is_a?(Symbol) ? card.to_s : card, state: state.to_s)
    end
  end

  module_function

  # ── configuration ──────────────────────────────────────────────────────────

  def programs(path = CONFIG_PATH)
    raw = YAML.safe_load(File.read(path)) || {}
    (raw["programs"] || {}).map do |name, spec|
      clusters = (spec["clusters"] || {}).map do |cluster, c|
        Cluster.new(name: cluster, program_id: c.fetch("program_id"), rpc_url: c.fetch("rpc_url"),
                    doc_section: c.fetch("doc_section"))
      end
      Program.new(name: name, github: spec.fetch("github"), source_branch: spec.fetch("source_branch"),
                  version_file: spec.fetch("version_file"), deployment_doc: spec.fetch("deployment_doc"),
                  card_slug: spec.fetch("card_slug"), clusters: clusters)
    end
  end

  # The program whose source lives in `repo` (bare name or owner/name), or nil.
  def program_for_repo(repo, list = programs)
    bare = repo.to_s.split("/").last.to_s.downcase
    list.find { |p| p.github.split("/").last.downcase == bare }
  end

  # ── pure parsing ───────────────────────────────────────────────────────────

  # The `version = "x.y.z"` line under [package] in a Cargo.toml, or nil. Only the
  # [package] table counts: a dependency's `version` key lives in another table.
  def parse_version(cargo_toml)
    table = nil
    cargo_toml.to_s.each_line do |line|
      stripped = line.strip
      if (header = stripped[/\A\[([^\]]+)\]/, 1])
        table = header.strip
        next
      end
      next unless table == "package"

      found = stripped[/\Aversion\s*=\s*"([^"]+)"/, 1]
      return found if found
    end
    nil
  end

  # The cluster's Version and Deployed-slot rows from the deployment doc's
  # `## <section>` block, as {version:, slot:}; nil when either row is missing.
  def parse_deployment(doc, section)
    block = doc.to_s.split(/^(?=## )/).find { |part| part.lines.first.to_s.strip == "## #{section}" }
    return nil unless block

    version = block[/^\|\s*Version\s*\|\s*v?(\d+\.\d+\.\d+)\s*\|/i, 1]
    slot = block[/^\|\s*Deployed\s*\|[^|\n]*slot\s+`?(\d+)`?/i, 1]
    return nil unless version && slot

    { version: version, slot: slot.to_i }
  end

  # 0.26.0 -> "v026", 0.26.1 -> "v026p1", 1.2.0 -> "v102".
  def version_token(version)
    major, minor, patch = version.to_s.split(".").map(&:to_i)
    token = format("v%<major>d%<minor>02d", major: major.to_i, minor: minor.to_i)
    patch.to_i.positive? ? "#{token}p#{patch}" : token
  end

  def card_slug(program, cluster_name, version)
    program.card_slug.gsub("{cluster}", cluster_name.to_s).gsub("{version}", version_token(version))
  end

  # The verdict for one cluster, from what was read. Every nil input is a reason.
  def classify(program:, cluster:, source_version:, deployment:, chain_slot:, chain_error: nil, source_error: nil)
    base = { program: program.name, cluster: cluster.name, source_version: source_version,
             chain_slot: chain_slot, doc_slot: deployment&.dig(:slot),
             deployed_version: deployment&.dig(:version) }
    reason =
      if source_version.nil?
        "cannot read the version in #{program.github}:#{program.version_file} on #{program.source_branch}" \
          "#{source_error ? " (#{source_error})" : ''}"
      elsif chain_slot.nil?
        "cannot read #{cluster.program_id} on #{cluster.name}#{chain_error ? " (#{chain_error})" : ''}"
      elsif deployment.nil?
        "cannot read the #{cluster.doc_section} Version and Deployed rows in #{program.github}:#{program.deployment_doc}"
      elsif chain_slot != deployment[:slot]
        "chain last deployed at slot #{chain_slot} but #{program.deployment_doc} records slot " \
          "#{deployment[:slot]}; re-derive the doc from chain before trusting its Version row"
      end
    return Reading.new(**base, state: :unconfirmed, reason: reason) if reason

    cmp = Gem::Version.new(deployment[:version]) <=> Gem::Version.new(source_version)
    state = { -1 => :behind, 0 => :current, 1 => :ahead }.fetch(cmp)
    Reading.new(**base, state: state,
                        card_slug: (state == :behind ? card_slug(program, cluster.name, source_version) : nil))
  rescue ArgumentError => e # a malformed version string
    Reading.new(**base, state: :unconfirmed, reason: "unparseable version (#{e.message})")
  end

  # ── live reads ─────────────────────────────────────────────────────────────

  # The last-deploy slot of an upgradeable program: the program account names its
  # ProgramData account, whose header carries the slot. Raises ReadError on anything
  # that is not exactly that shape.
  def last_deploy_slot(rpc_url, program_id, rpc: method(:rpc_call))
    account = rpc.call(rpc_url, "getAccountInfo", [program_id, { "encoding" => "jsonParsed" }])
    value = account && account["value"]
    raise ReadError, "program account not found" unless value
    raise ReadError, "not owned by the upgradeable loader" unless value["owner"] == UPGRADEABLE_LOADER

    data_address = value.dig("data", "parsed", "info", "programData")
    raise ReadError, "program account names no ProgramData" if data_address.to_s.empty?

    header = rpc.call(rpc_url, "getAccountInfo",
                      [data_address, { "encoding" => "base64", "dataSlice" => { "offset" => 0, "length" => 13 } }])
    encoded = header && header.dig("value", "data", 0)
    raise ReadError, "ProgramData account not found" unless encoded

    bytes = Base64.decode64(encoded)
    raise ReadError, "ProgramData header too short" if bytes.bytesize < HEADER_BYTES

    tag, slot = bytes.unpack("L<Q<")
    raise ReadError, "ProgramData tag #{tag}, expected #{PROGRAM_DATA_TAG}" unless tag == PROGRAM_DATA_TAG

    slot
  end

  def rpc_call(url, method, params)
    uri = URI(ENV[RPC_OVERRIDE_ENV].to_s.empty? ? url : ENV[RPC_OVERRIDE_ENV])
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    req = Net::HTTP::Post.new(uri.request_uri.empty? ? "/" : uri.request_uri, "Content-Type" => "application/json")
    req.body = JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params)
    res = http.request(req)
    raise ReadError, "#{method} answered HTTP #{res.code}" unless res.code.to_i == 200

    body = JSON.parse(res.body)
    raise ReadError, "#{method}: #{body.dig('error', 'message')}" if body["error"]

    body["result"]
  rescue ReadError
    raise
  rescue StandardError => e
    raise ReadError, "#{e.class}: #{e.message}"[0, 160]
  end

  # One file from GitHub at `ref`, through `gh api` (CiStatus.gh_read_status, which
  # refreshes an aging App token). Returns [text, nil] or [nil, reason].
  def github_file(github, path, ref, gh: nil)
    gh ||= lambda do |*args|
      require_relative "ci_status"
      CiStatus.gh_read_status(*args)
    end
    out, ok = gh.call("api", "repos/#{github}/contents/#{path}?ref=#{ref}", "--jq", ".content")
    unless ok
      said = out.to_s.lines.first.to_s.strip[0, 120]
      return [nil, "gh api failed#{said.empty? ? '' : ": #{said}"}"]
    end

    text = Base64.decode64(out.to_s)
    text.strip.empty? ? [nil, "empty file"] : [text.force_encoding(Encoding::UTF_8), nil]
  end

  # ── orchestration ──────────────────────────────────────────────────────────

  # The raw inputs for one program: the source version, the parsed doc per cluster,
  # and each cluster's chain slot (or the error that stopped it). Clusters are read
  # in parallel so status pays for the slowest cluster, not the sum.
  def gather(program, gh: nil, rpc: method(:rpc_call))
    source_text, source_error = github_file(program.github, program.version_file, program.source_branch, gh: gh)
    doc_text, = github_file(program.github, program.deployment_doc, program.source_branch, gh: gh)
    threads = program.clusters.to_h do |cluster|
      [cluster.name, Thread.new do
        { slot: last_deploy_slot(cluster.rpc_url, cluster.program_id, rpc: rpc) }
      rescue ReadError => e
        { error: e.message }
      end]
    end
    {
      "source_version" => source_text && parse_version(source_text),
      "source_error" => source_error,
      "deployments" => program.clusters.to_h { |c| [c.name, doc_text && parse_deployment(doc_text, c.doc_section)] },
      "chain" => threads.transform_values(&:value)
    }
  end

  # Readings for every configured program. `cache:` is a file path, or nil for none.
  # Only a COMPLETE gather (every input read) is cached, so a failure is re-read on
  # the next call instead of being remembered.
  def readings(programs: self.programs, cache: nil, fresh: false, gh: nil, rpc: method(:rpc_call), now: Time.now)
    stored = cache && !fresh ? read_cache(cache, now) : {}
    out = []
    updated = stored.dup
    programs.each do |program|
      inputs = stored[program.name] || gather(program, gh: gh, rpc: rpc)
      updated[program.name] = inputs.merge("at" => now.to_i) if complete?(inputs)
      out.concat(readings_from(program, inputs))
    end
    write_cache(cache, updated) if cache && updated != stored
    out
  end

  def readings_from(program, inputs)
    program.clusters.map do |cluster|
      chain = inputs.dig("chain", cluster.name) || {}
      dep = inputs.dig("deployments", cluster.name)
      classify(program: program, cluster: cluster, source_version: inputs["source_version"],
               deployment: dep && { version: dep[:version] || dep["version"], slot: dep[:slot] || dep["slot"] },
               chain_slot: chain[:slot] || chain["slot"], chain_error: chain[:error] || chain["error"],
               source_error: inputs["source_error"])
    end
  end

  def complete?(inputs)
    inputs["source_version"] && inputs["deployments"].values.all? &&
      inputs["chain"].values.all? { |c| c[:slot] || c["slot"] }
  end

  def read_cache(path, now)
    data = JSON.parse(File.read(path))
    data.select { |_name, inputs| inputs.is_a?(Hash) && now.to_i - inputs["at"].to_i < CACHE_TTL }
  rescue StandardError
    {}
  end

  def write_cache(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(data))
  rescue StandardError
    nil # a cache that cannot be written only costs the next call a re-read
  end

  # Fill each behind reading's `card` from `lookup` (slug -> Hash | nil | :unknown).
  # An archived card is not an open card, so it reads as none.
  def attach_cards(readings, lookup)
    readings.each do |reading|
      next unless reading.card_slug

      found = begin
        lookup.call(reading.card_slug)
      rescue StandardError
        :unknown
      end
      found = nil if found.is_a?(Hash) && found["stage"].to_s == "archived"
      reading.card = found
    end
  end

  # The board lookup for attach_cards, through the agent API. Answers :unknown when
  # the board cannot be read, never nil, so an outage cannot read as "no card".
  def board_lookup(api: nil)
    require_relative "agent_api"
    api ||= AgentApi.new(open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
    token = nil
    minted = false
    lambda do |slug|
      # Minted on the first lookup, not up front: a run with no drift asks the board nothing.
      token = api.token unless minted
      minted = true
      next :unknown unless token

      res = api.http_get("/api/v1/tasks/#{slug}", bearer: token)
      next :unknown unless res
      next nil if res.code.to_i == 404
      next :unknown unless res.code.to_i.between?(200, 299)

      data = JSON.parse(res.body)["data"]
      data.is_a?(Hash) ? { "slug" => data["slug"], "stage" => data["stage"] } : :unknown
    end
  end

  # ── rendering ──────────────────────────────────────────────────────────────

  def lines(readings)
    readings.map { |r| line(r) }
  end

  def line(reading)
    where = "#{reading.program} #{reading.cluster}"
    case reading.state
    when :current
      "program #{where}: current at v#{reading.source_version} (chain slot #{reading.chain_slot})"
    when :behind
      "PROGRAM DRIFT #{where}: chain runs v#{reading.deployed_version} (slot #{reading.chain_slot}), " \
        "source is v#{reading.source_version} — #{card_phrase(reading)}"
    when :ahead
      "PROGRAM DRIFT #{where}: chain runs v#{reading.deployed_version}, AHEAD of the source " \
        "v#{reading.source_version}; the source branch or the doc is wrong"
    else
      "PROGRAM DRIFT #{where}: cannot confirm the deployed version — #{reading.reason}"
    end
  end

  def card_phrase(reading)
    case reading.card
    when Hash then "upgrade card #{reading.card['slug']} (#{reading.card['stage']})"
    when :unknown then "upgrade card #{reading.card_slug} unknown (board unreadable)"
    else "NO upgrade card: file #{reading.card_slug} (#{SOP})"
    end
  end

  # Process exit for bin/program-drift: 0 all current, 1 a cluster behind or ahead,
  # 2 a cluster could not be confirmed (the worst wins).
  def exit_code(readings)
    return 2 if readings.any? { |r| r.state == :unconfirmed }
    return 1 if readings.any?(&:drift?)

    0
  end

  # The cache file, in the system temp dir: shared by every desk on this machine, so
  # one read serves every status call for CACHE_TTL. Deliberately NOT under
  # <projects>/.agents — that tree is the operator's guarded state store
  # (lib/task_usage_sandbox.rb), and a re-readable cache does not belong in it.
  def default_cache_path
    File.join(Dir.tmpdir, "mcritchie-program-drift.json")
  end
end
