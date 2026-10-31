# frozen_string_literal: true

# [unit] The vault permission map in docs/agents/modules/credential-access.md is
# the same map as bin/lib/op_vaults.rb (OpVaults::LANES and OpVaults::VAULTS), both
# ways, and its soul classes match AgentSession::ADMIN_SOULS.
#
# WHY. The map is the organization Alex McRitchie asked for before permissions move
# to separate machines. A table that drifts from the code is worse than none: an
# agent reads the doc, and the code decides. So a vault, a lane, a token or a future
# machine changed in one place without the other fails here.
#
#   ruby -Itest test/lib/credential_access_vault_map_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/op_vaults"

class CredentialAccessVaultMapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SOP = File.join(ROOT, "docs/agents/modules/credential-access.md")
  AGENT_SESSION = File.join(ROOT, "app/models/agent_session.rb")

  def text = File.read(SOP)

  def cells(line) = line.split("|")[1..].map(&:strip)

  def ticked(cell) = cell.scan(/`([^`]+)`/).flatten

  # vault => { readers: [...], machine: "..." }, from the marked table.
  def doc_vaults
    block = text[/<!-- vault-map:start -->(.*?)<!-- vault-map:end -->/m, 1]
    refute_nil block, "the SOP lost its vault-map markers"
    block.lines.select { |l| l.start_with?("| `") }.to_h do |line|
      vault, _holds, readers, machine = cells(line)
      [ticked(vault).first, { readers: ticked(readers).map(&:to_sym).sort, machine: machine }]
    end
  end

  # lane => [token, profile], from the lane table above the vault map.
  def doc_lanes
    text.lines.select { |l| l =~ /\A\| `(agent|deployer)` \|/ }.to_h do |line|
      lane, token, loaded, _class = cells(line)
      [ticked(lane).first.to_sym, [ticked(token).first, ticked(loaded).first]]
    end
  end

  def test_every_vault_in_the_code_is_in_the_doc_and_the_reverse
    code = OpVaults::VAULTS.transform_values { |v| { readers: v[:readers].sort, machine: v[:machine].to_s } }

    assert_equal code.keys.sort, doc_vaults.keys.sort, "the two vault lists differ"
    code.each do |vault, spec|
      assert_equal spec, doc_vaults[vault], "#{vault}: readers or future machine differ between doc and OpVaults::VAULTS"
    end
  end

  def test_every_lane_names_its_token_and_profile_as_the_code_does
    assert_equal OpVaults::LANES.keys.sort, doc_lanes.keys.sort
    OpVaults::LANES.each do |lane, spec|
      assert_equal [spec[:token_env], spec[:profile]], doc_lanes[lane], "#{lane}: token or profile differs"
    end
  end

  # Each lane's own vault is one it can read, so the map and the routing agree.
  def test_each_lane_reads_its_default_vault
    OpVaults::LANES.each do |lane, spec|
      readers = OpVaults::VAULTS.fetch(spec[:default_vault]) { flunk "#{spec[:default_vault]} is not in VAULTS" }[:readers]
      assert_includes readers, lane, "#{lane} cannot read its own default vault #{spec[:default_vault]}"
    end
  end

  # The admin vault is the deployer's alone: the isolation the two tokens exist for.
  def test_no_worker_lane_reads_the_admin_vault
    admin = OpVaults::LANES.fetch(:deployer).fetch(:default_vault)
    assert_equal %i[deployer], OpVaults::VAULTS.fetch(admin)[:readers]
  end

  def test_the_admin_class_is_agent_session_admin_souls_and_worker_names_alex_and_mack
    souls = File.read(AGENT_SESSION)[/ADMIN_SOULS = %w\[([^\]]*)\]/, 1].to_s.split
    refute_empty souls, "AgentSession::ADMIN_SOULS moved; repoint this test"
    admin_line = text.lines.find { |l| l.include?("**Admin class** is `AgentSession::ADMIN_SOULS`") }.to_s
    souls.each { |soul| assert_includes admin_line.downcase, soul, "#{soul} is admin in code but not named in the SOP" }
    worker = text[/\*\*Worker class\*\*.*?(?=\n- )/m].to_s
    assert_match(/Alex \(the agent\) and Mack are Worker class/, worker)
  end
end
