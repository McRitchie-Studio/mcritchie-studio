require "test_helper"
require_relative "../../bin/lib/agent_domain_registry"

# [unit] The domain registry (config/agent_domains.yml through
# AgentMailbox::DomainRegistry): the shipped file loads, each front door sees
# only its own catalog filtered by audience, and a proposal is refused unless
# it names this soul's own capability, fits the schema and may be requested.
class AgentDomainRegistryTest < ActiveSupport::TestCase
  Audience = AgentMailbox::Audience

  def setup
    @registry = AgentMailbox::DomainRegistry.load
    @owner = Audience.new(role: "owner")
    @team = Audience.new(role: "team")
    @public = Audience.new(role: "public")
  end

  def ask(name, params = {}) = { "kind" => "ask", "capability" => name, "params" => params, "summary" => "s" }

  def change(params = {})
    { "kind" => "change", "capability" => "task", "summary" => "Footer toggle",
      "params" => { "title" => "Footer Theme Toggle Added", "accept" => [ "The footer toggles light and dark" ],
                    "test" => [ "[unit] the toggle renders" ] }.merge(params) }
  end

  def test_the_shipped_registry_names_each_front_door
    assert_equal "mcritchie_studio", @registry.front_door("xan")["key"]
    assert_equal "turf_monster", @registry.front_door("turf_monster")["key"]
    assert_nil @registry.front_door("avi"), "avi answers for the studio domain but is not its front door"
    assert_equal "mcritchie_studio", @registry.domain_key_for("avi"), "the DOMAIN layer mapping still loads"
    assert_equal "Turf", @registry.reply_name("turf_monster")
    assert_includes @registry.shapes, "backend", "shapes come from config/feature_shapes.yml"
  end

  def test_the_catalog_is_the_souls_own_and_filtered_by_audience
    xan = @registry.catalog("xan", audience: @owner).map { |c| c["capability"] }
    turf = @registry.catalog("turf_monster", audience: @owner).map { |c| c["capability"] }
    assert_equal %w[board_status recently_shipped task], xan
    assert_equal %w[signups_and_errors task], turf
    assert_empty @registry.catalog("avi", audience: @owner)
    assert_equal %w[board_status recently_shipped task], @registry.catalog("xan", audience: @team).map { |c| c["capability"] }
    assert_equal %w[task], @registry.catalog("turf_monster", audience: @team).map { |c| c["capability"] },
                 "signups are owner-only"
    assert_empty @registry.catalog("xan", audience: @public)
    joined = @registry.catalog("xan", audience: @owner).inspect + @registry.catalog("turf_monster", audience: @owner).inspect
    refute_match(/welding/i, joined, "an internal domain is never named in a catalog")
  end

  def test_a_valid_ask_is_normalized_with_its_default
    verdict = @registry.validate(soul: "xan", audience: @owner, proposal: ask("recently_shipped"))
    assert verdict.ok?, verdict.reason
    assert_equal({ "days" => 7 }, verdict.proposal["params"])
    verdict = @registry.validate(soul: "xan", audience: @owner, proposal: ask("recently_shipped", "days" => "3"))
    assert_equal({ "days" => 3 }, verdict.proposal["params"])
  end

  def test_an_unknown_capability_is_refused
    verdict = @registry.validate(soul: "xan", audience: @owner, proposal: ask("drop_tables"))
    refute verdict.ok?
    assert_match(/not in mcritchie_studio's catalog/, verdict.reason)
  end

  def test_another_domains_capability_is_refused
    verdict = @registry.validate(soul: "xan", audience: @owner, proposal: ask("signups_and_errors"))
    refute verdict.ok?, "Xan cannot propose Turf's query"
    verdict = @registry.validate(soul: "turf_monster", audience: @owner, proposal: ask("board_status"))
    refute verdict.ok?, "Turf cannot propose Xan's query"
  end

  def test_an_insufficient_audience_is_refused
    verdict = @registry.validate(soul: "turf_monster", audience: @team, proposal: ask("signups_and_errors"))
    refute verdict.ok?
    assert_match(/team may not request ask signups_and_errors/, verdict.reason)
    refute @registry.validate(soul: "xan", audience: @public, proposal: change).ok?
    refute @registry.validate(soul: "xan", audience: nil, proposal: ask("board_status")).ok?, "no audience fails closed"
  end

  def test_a_client_may_request_a_change_only_in_its_own_domain
    turf_client = Audience.new(role: "client", client_domain: "turf_monster")
    assert @registry.validate(soul: "turf_monster", audience: turf_client, proposal: change).ok?
    refute @registry.validate(soul: "xan", audience: turf_client, proposal: change).ok?
    refute @registry.validate(soul: "turf_monster", audience: turf_client, proposal: ask("signups_and_errors")).ok?
  end

  def test_params_must_fit_the_schema
    refute @registry.validate(soul: "xan", audience: @owner, proposal: ask("recently_shipped", "days" => 31)).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: ask("recently_shipped", "days" => "7; DROP")).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: ask("board_status", "sql" => "x")).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: ask("board_status").merge("params" => "x")).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: change("shape" => "rocket")).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: change("accept" => [])).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: change("test" => %w[a b c d e f])).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: { "kind" => "deploy", "capability" => "x" }).ok?
    refute @registry.validate(soul: "xan", audience: @owner, proposal: "go").ok?
  end

  def test_a_change_takes_the_template_defaults_and_plain_text
    verdict = @registry.validate(soul: "xan", audience: @owner,
                                 proposal: change("title" => "Footer <@123> Toggle\nNow").merge("summary" => "@everyone hi"))
    assert verdict.ok?, verdict.reason
    params = verdict.proposal["params"]
    assert_equal "feature", params["kind"]
    assert_equal "backend", params["shape"]
    assert_equal "Footer Toggle Now", params["title"]
    assert_equal "hi", verdict.proposal["summary"]
  end

  def test_operate_is_empty_in_phase_one
    refute @registry.validate(soul: "turf_monster", audience: @owner,
                              proposal: { "kind" => "operate", "capability" => "content_build", "params" => {} }).ok?
  end
end
