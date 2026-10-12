# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "base64"
require "json"
require_relative "../../bin/lib/program_drift"

# [unit] ProgramDrift — the read-only check that a cluster runs the program version
# its source branch carries. Every network read is injected: `gh:` stands in for
# `gh api`, `rpc:` for the JSON-RPC call, and a lambda for the board.
class ProgramDriftTest < Minitest::Test
  CARGO = <<~TOML
    [package]
    name = "turf_vault"
    version = "0.26.0"

    [dependencies.anchor-lang]
    version = "0.31.1"
  TOML

  DOC = <<~MD
    # Current Deployment

    ## Devnet

    | Field | Value |
    |-------|-------|
    | Program ID | `DEVNETPROGRAM` |
    | Version | v0.25.0 |
    | Deployed | 2026-06-11, slot `468716417` |

    ## Mainnet

    | Field | Value |
    |-------|-------|
    | Program ID | `MAINNETPROGRAM` |
    | Version | v0.25.0 |
    | Deployed | 2026-06-11, slot `425788802` |
  MD

  def program
    @program ||= ProgramDrift::Program.new(
      name: "turf-vault", github: "Org/turf-vault", source_branch: "main",
      version_file: "programs/turf_vault/Cargo.toml", deployment_doc: "docs/CURRENT_DEPLOYMENT.md",
      card_slug: "{cluster}-{version}-upgrade",
      clusters: [
        ProgramDrift::Cluster.new(name: "devnet", program_id: "DEVNETPROGRAM", rpc_url: "https://devnet.test",
                                  doc_section: "Devnet"),
        ProgramDrift::Cluster.new(name: "mainnet", program_id: "MAINNETPROGRAM", rpc_url: "https://mainnet.test",
                                  doc_section: "Mainnet")
      ]
    )
  end

  # A fake `gh api repos/<github>/contents/<path>?ref=<ref> --jq .content`.
  def gh_serving(files)
    lambda do |*args|
      path = args[1][%r{contents/([^?]+)}, 1]
      text = files[path]
      text ? [Base64.strict_encode64(text), true] : ["HTTP 404: Not Found", false]
    end
  end

  # A fake RPC that serves a program account and its ProgramData header per cluster.
  def rpc_serving(slots, owner: ProgramDrift::UPGRADEABLE_LOADER, tag: 3)
    lambda do |url, _method, params|
      slot = slots[url]
      raise ProgramDrift::ReadError, "connection refused" if slot.nil?

      if params[1]["encoding"] == "jsonParsed"
        { "value" => { "owner" => owner, "data" => { "parsed" => { "info" => { "programData" => "PD#{url}" } } } } }
      else
        { "value" => { "data" => [Base64.strict_encode64([tag, slot, 1].pack("L<Q<C")), "base64"] } }
      end
    end
  end

  def live_inputs(devnet_slot: 468_716_417, mainnet_slot: 425_788_802, cargo: CARGO)
    {
      gh: gh_serving("programs/turf_vault/Cargo.toml" => cargo, "docs/CURRENT_DEPLOYMENT.md" => DOC),
      rpc: rpc_serving({ "https://devnet.test" => devnet_slot, "https://mainnet.test" => mainnet_slot })
    }
  end

  # ── parsing ──────────────────────────────────────────────────────────────

  def test_parse_version_reads_only_the_package_table
    assert_equal "0.26.0", ProgramDrift.parse_version(CARGO)
    assert_nil ProgramDrift.parse_version("[dependencies.x]\nversion = \"9.9.9\"\n"),
               "a dependency's version key is not the crate's version"
  end

  def test_parse_deployment_reads_each_section_on_its_own
    assert_equal({ version: "0.25.0", slot: 468_716_417 }, ProgramDrift.parse_deployment(DOC, "Devnet"))
    assert_equal({ version: "0.25.0", slot: 425_788_802 }, ProgramDrift.parse_deployment(DOC, "Mainnet"))
    assert_nil ProgramDrift.parse_deployment(DOC, "Testnet")
    assert_nil ProgramDrift.parse_deployment(DOC.sub(/^\| Deployed .*\n/, ""), "Devnet"),
               "a section with no Deployed slot cannot be checked against the chain"
  end

  def test_version_token_and_card_slug_follow_the_card_convention
    assert_equal "v026", ProgramDrift.version_token("0.26.0")
    assert_equal "v026p1", ProgramDrift.version_token("0.26.1")
    assert_equal "v102", ProgramDrift.version_token("1.2.0")
    assert_equal "devnet-v026-upgrade", ProgramDrift.card_slug(program, "devnet", "0.26.0")
    assert_equal "mainnet-v026-upgrade", ProgramDrift.card_slug(program, "mainnet", "0.26.0")
  end

  # ── the three verdicts the card names: equal, behind, unreadable ─────────

  def test_equal_versions_read_current
    readings = ProgramDrift.readings(programs: [program], **live_inputs(cargo: CARGO.sub("0.26.0", "0.25.0")))

    assert_equal %i[current current], readings.map(&:state)
    assert_equal 0, ProgramDrift.exit_code(readings)
    assert_match(/program turf-vault devnet: current at v0.25.0/, ProgramDrift.line(readings.first))
  end

  def test_source_ahead_of_chain_reads_behind_and_names_the_card
    readings = ProgramDrift.readings(programs: [program], **live_inputs)

    assert_equal %i[behind behind], readings.map(&:state)
    assert_equal %w[devnet-v026-upgrade mainnet-v026-upgrade], readings.map(&:card_slug)
    assert_equal 1, ProgramDrift.exit_code(readings)
  end

  def test_unreadable_chain_fails_closed_never_current
    inputs = live_inputs
    inputs[:rpc] = rpc_serving({ "https://devnet.test" => 468_716_417 }) # mainnet refuses
    readings = ProgramDrift.readings(programs: [program], **inputs)

    mainnet = readings.last
    assert_equal :unconfirmed, mainnet.state
    assert_match(/cannot confirm the deployed version — cannot read MAINNETPROGRAM on mainnet \(connection refused\)/,
                 ProgramDrift.line(mainnet))
    assert_equal 2, ProgramDrift.exit_code(readings), "unconfirmed outranks behind"
  end

  def test_doc_alone_is_not_proof_a_later_deploy_makes_it_unconfirmed
    readings = ProgramDrift.readings(programs: [program], **live_inputs(devnet_slot: 500_000_000))

    devnet = readings.first
    assert_equal :unconfirmed, devnet.state, "the chain moved since the doc was written; its Version row is stale"
    assert_match(/chain last deployed at slot 500000000 but docs\/CURRENT_DEPLOYMENT.md records slot 468716417/,
                 devnet.reason)
  end

  def test_unreadable_source_fails_closed
    inputs = live_inputs
    inputs[:gh] = ->(*_args) { ["HTTP 401: Bad credentials", false] }
    readings = ProgramDrift.readings(programs: [program], **inputs)

    assert_equal %i[unconfirmed unconfirmed], readings.map(&:state)
    assert_match(/cannot read the version in Org\/turf-vault:programs\/turf_vault\/Cargo.toml on main/,
                 readings.first.reason)
  end

  def test_chain_reader_refuses_a_foreign_owner_and_a_wrong_tag
    assert_raises(ProgramDrift::ReadError) do
      ProgramDrift.last_deploy_slot("https://devnet.test", "X", rpc: rpc_serving({ "https://devnet.test" => 1 }, owner: "Other"))
    end
    assert_raises(ProgramDrift::ReadError) do
      ProgramDrift.last_deploy_slot("https://devnet.test", "X", rpc: rpc_serving({ "https://devnet.test" => 1 }, tag: 2))
    end
    assert_equal 42, ProgramDrift.last_deploy_slot("https://devnet.test", "X",
                                                   rpc: rpc_serving({ "https://devnet.test" => 42 }))
  end

  def test_chain_ahead_of_source_is_drift_not_current
    readings = ProgramDrift.readings(programs: [program], **live_inputs(cargo: CARGO.sub("0.26.0", "0.24.0")))

    assert_equal %i[ahead ahead], readings.map(&:state)
    assert_match(/AHEAD of the source/, ProgramDrift.line(readings.first))
  end

  # ── cards ────────────────────────────────────────────────────────────────

  def test_lines_name_the_card_or_say_none_exists
    readings = ProgramDrift.readings(programs: [program], **live_inputs)
    ProgramDrift.attach_cards(readings, lambda { |slug|
      slug == "devnet-v026-upgrade" ? { "slug" => slug, "stage" => "designed" } : nil
    })
    devnet, mainnet = ProgramDrift.lines(readings)

    assert_equal "PROGRAM DRIFT turf-vault devnet: chain runs v0.25.0 (slot 468716417), source is v0.26.0 — " \
                 "upgrade card devnet-v026-upgrade (designed)", devnet
    assert_match(/PROGRAM DRIFT turf-vault mainnet: .* NO upgrade card: file mainnet-v026-upgrade/, mainnet)
  end

  def test_archived_card_reads_as_none_and_a_board_failure_reads_as_unknown
    readings = ProgramDrift.readings(programs: [program], **live_inputs)
    ProgramDrift.attach_cards(readings, lambda { |slug|
      raise "board down" if slug.start_with?("mainnet")

      { "slug" => slug, "stage" => "archived" }
    })

    assert_nil readings.first.card, "an archived card is not an open card"
    assert_equal :unknown, readings.last.card, "an outage is never read as 'no card'"
    assert_match(/unknown \(board unreadable\)/, ProgramDrift.line(readings.last))
  end

  def test_board_lookup_maps_404_to_none_and_errors_to_unknown
    response = Struct.new(:code, :body)
    api = Object.new
    api.define_singleton_method(:token) { "t" }
    api.define_singleton_method(:http_get) do |path, bearer:|
      raise "no bearer" unless bearer == "t"

      case path
      when %r{/devnet-v026-upgrade\z} then response.new("200", JSON.generate(data: { slug: "devnet-v026-upgrade", stage: "designed" }))
      when %r{/missing\z} then response.new("404", "")
      else response.new("500", "boom")
      end
    end
    lookup = ProgramDrift.board_lookup(api: api)

    assert_equal({ "slug" => "devnet-v026-upgrade", "stage" => "designed" }, lookup.call("devnet-v026-upgrade"))
    assert_nil lookup.call("missing")
    assert_equal :unknown, lookup.call("other")
  end

  # ── the cache keeps status fast without remembering a failure ────────────

  def test_cache_serves_a_complete_read_and_never_stores_a_failed_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "drift.json")
      ProgramDrift.readings(programs: [program], cache: path, **live_inputs)
      assert File.exist?(path)

      dead = { gh: ->(*_a) { flunk "a fresh cache must not re-read GitHub" },
               rpc: ->(*_a) { flunk "a fresh cache must not re-read the chain" } }
      assert_equal %i[behind behind], ProgramDrift.readings(programs: [program], cache: path, **dead).map(&:state)

      later = Time.now + ProgramDrift::CACHE_TTL + 1
      refused = { gh: ->(*_a) { ["down", false] }, rpc: ->(*_a) { raise ProgramDrift::ReadError, "down" } }
      stale = ProgramDrift.readings(programs: [program], cache: path, now: later, **refused)
      assert_equal %i[unconfirmed unconfirmed], stale.map(&:state), "an expired cache is re-read, not trusted"
      assert_equal 1, JSON.parse(File.read(path)).size
    end
  end

  # ── the upgrade reserve: warns below the next float, and below the minimum ──

  SOL = ProgramDrift::LAMPORTS_PER_SOL

  def reserved_cluster(headroom_sol: 1)
    ProgramDrift::Cluster.new(
      name: "mainnet", program_id: "MAINNETPROGRAM", rpc_url: "https://mainnet.test", doc_section: "Mainnet",
      reserve: ProgramDrift::Reserve.new(address: "RESERVEVAULT", label: "mainnet Squad vault",
                                         headroom_lamports: headroom_sol * SOL)
    )
  end

  def reserved_program
    ProgramDrift::Program.new(name: "turf-vault", github: "Org/turf-vault", source_branch: "main",
                              version_file: "x", deployment_doc: "y", card_slug: "{cluster}-{version}-upgrade",
                              clusters: [program.clusters.first, reserved_cluster])
  end

  # A fake RPC for the reserve read: the program account, its ProgramData size, the
  # rent the cluster quotes per byte, and the reserve's balance. `calls` records each.
  def reserve_rpc(balance:, space: 707_645, rent_per_byte: 5_080, calls: [])
    lambda do |_url, method, params|
      calls << [method, params]
      case method
      when "getAccountInfo"
        if params[1]["encoding"] == "jsonParsed"
          { "value" => { "owner" => ProgramDrift::UPGRADEABLE_LOADER,
                         "data" => { "parsed" => { "info" => { "programData" => "PROGRAMDATA" } } } } }
        else
          { "value" => { "data" => ["", "base64"], "space" => space } }
        end
      when "getMinimumBalanceForRentExemption" then (params[0] + 128) * rent_per_byte
      when "getBalance" then { "context" => { "slot" => 1 }, "value" => balance }
      else raise "unexpected #{method}"
      end
    end
  end

  def test_reserve_float_is_the_rent_of_a_buffer_the_size_of_the_deployed_program
    calls = []
    reading = ProgramDrift.reserve_readings(programs: [reserved_program],
                                            rpc: reserve_rpc(balance: 10_304_529_006, calls: calls)).first

    # 707,645-byte ProgramData less its 45-byte header = 707,600 program bytes; the
    # buffer adds 37, and rent is asked for exactly that size.
    assert_equal 707_600, reading.program_bytes
    assert_includes calls, ["getMinimumBalanceForRentExemption", [707_637]]
    assert_includes calls, ["getBalance", ["RESERVEVAULT"]]
    assert_equal (707_637 + 128) * 5_080, reading.float
    assert_equal reading.float + SOL, reading.minimum
    assert_equal :ok, reading.state
    assert_equal "upgrade reserve turf-vault mainnet: mainnet Squad vault RESE… holds 10.3045 SOL; " \
                 "next float 3.5954 SOL, minimum 4.5954 SOL", ProgramDrift.reserve_line(reading)
  end

  def test_reserve_below_the_float_warns_short
    reading = ProgramDrift.reserve_readings(programs: [reserved_program], rpc: reserve_rpc(balance: 3 * SOL)).first

    assert_equal :short, reading.state
    assert_match(/\AUPGRADE RESERVE SHORT turf-vault mainnet: mainnet Squad vault RESE… holds 3\.0000 SOL, less than the next upgrade's float 3\.5954 SOL/,
                 ProgramDrift.reserve_line(reading))
  end

  def test_reserve_above_the_float_but_below_the_minimum_warns_low
    reading = ProgramDrift.reserve_readings(programs: [reserved_program], rpc: reserve_rpc(balance: 4 * SOL)).first

    assert_equal :low, reading.state
    assert_match(/\AUPGRADE RESERVE LOW .* holds 4\.0000 SOL, below the minimum 4\.5954 SOL/,
                 ProgramDrift.reserve_line(reading))
  end

  def test_reserve_boundaries_are_inclusive_of_the_float_and_the_minimum
    float = (707_637 + 128) * 5_080
    states = [float - 1, float, float + SOL - 1, float + SOL].map do |balance|
      ProgramDrift.reserve_readings(programs: [reserved_program], rpc: reserve_rpc(balance: balance)).first.state
    end

    assert_equal %i[short low low ok], states
  end

  def test_reserve_float_follows_the_rent_the_cluster_quotes
    cheap = ProgramDrift.reserve_readings(programs: [reserved_program],
                                          rpc: reserve_rpc(balance: 4 * SOL, rent_per_byte: 3_000)).first
    dear = ProgramDrift.reserve_readings(programs: [reserved_program],
                                         rpc: reserve_rpc(balance: 4 * SOL, rent_per_byte: 6_960)).first

    assert_equal %i[ok short], [cheap.state, dear.state], "a rent change moves the float; nothing is hard-coded"
  end

  def test_unreadable_reserve_fails_closed_never_ok
    down = ->(*_a) { raise ProgramDrift::ReadError, "connection refused" }
    reading = ProgramDrift.reserve_readings(programs: [reserved_program], rpc: down).first

    assert_equal :unconfirmed, reading.state
    assert_equal "UPGRADE RESERVE turf-vault mainnet: cannot confirm — cannot read mainnet Squad vault on mainnet " \
                 "(connection refused)", ProgramDrift.reserve_line(reading)

    no_size = reserve_rpc(balance: 9 * SOL, space: nil)
    assert_equal :unconfirmed,
                 ProgramDrift.reserve_readings(programs: [reserved_program], rpc: no_size).first.state,
                 "an RPC that reports no ProgramData size cannot price the float"
  end

  def test_clusters_without_a_reserve_read_nothing
    calls = []
    out = ProgramDrift.reserve_readings(programs: [program], rpc: reserve_rpc(balance: 0, calls: calls))

    assert_empty out
    assert_empty calls
  end

  def test_reserve_cache_serves_a_complete_read_and_never_stores_a_failed_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "reserve.json")
      ProgramDrift.reserve_readings(programs: [reserved_program], cache: path, rpc: reserve_rpc(balance: 9 * SOL))
      cached = ProgramDrift.reserve_readings(programs: [reserved_program], cache: path,
                                             rpc: ->(*_a) { flunk "a fresh cache must not re-read the chain" })
      assert_equal %i[ok], cached.map(&:state)

      refused = ->(*_a) { raise ProgramDrift::ReadError, "down" }
      later = Time.now + ProgramDrift::CACHE_TTL + 1
      assert_equal %i[unconfirmed],
                   ProgramDrift.reserve_readings(programs: [reserved_program], cache: path, now: later,
                                                 rpc: refused).map(&:state)
    end
  end

  def test_config_names_the_mainnet_squad_vault_as_the_only_reserve
    tv = ProgramDrift.programs.find { |p| p.name == "turf-vault" }
    devnet, mainnet = tv.clusters

    assert_nil devnet.reserve
    assert_equal "Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm", mainnet.reserve.address
    assert_equal SOL, mainnet.reserve.headroom_lamports, "the SOP's minimum is the float plus 1 SOL"
  end

  # ── configuration ────────────────────────────────────────────────────────

  def test_config_lists_turf_vault_on_both_clusters_devnet_first
    tv = ProgramDrift.programs.find { |p| p.name == "turf-vault" }

    assert_equal "McRitchie-Studio/turf-vault", tv.github
    assert_equal "programs/turf_vault/Cargo.toml", tv.version_file
    assert_equal %w[devnet mainnet], tv.clusters.map(&:name)
    assert_equal %w[EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM],
                 tv.clusters.map(&:program_id)
  end

  def test_no_program_id_is_written_into_the_logic
    sources = [File.expand_path("../../bin/lib/program_drift.rb", __dir__),
               File.expand_path("../../bin/lib/dor/checks/program_upgrade_cards.rb", __dir__),
               File.expand_path("../../bin/program-drift", __dir__)].map { |f| File.read(f) }
    ProgramDrift.programs.flat_map(&:clusters).each do |cluster|
      sources.each { |src| refute_includes src, cluster.program_id, "program IDs live in config/onchain_programs.yml" }
      next unless cluster.reserve

      sources.each { |src| refute_includes src, cluster.reserve.address, "reserve addresses live in the config too" }
    end
  end
end
