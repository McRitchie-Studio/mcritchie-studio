# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../bin/lib/sop_registry"

# The SOP Registry table (docs/agents/index.md, installed as AGENTS.md) and the Start
# Here SOP rows are GENERATED from the SOP files by bin/sop-registry. These cases pin
# the generator's rule over a fixture tree, and that the committed blocks are what it
# writes, so a new SOP file is registered by `bin/sop-registry --write` and nothing else.
class SopRegistryGeneratedTest < ActiveSupport::TestCase
  ROOT = Rails.root.to_s

  test "[unit] the committed registry and Start Here blocks are what the generator writes" do
    assert_empty SopRegistry.stale(ROOT),
                 "a generated SOP block is stale. Run bin/sop-registry --write and commit the result."
  end

  test "[unit] the generator reads a real tree" do
    entries = SopRegistry.entries(ROOT)

    assert_operator entries.size, :>=, 40, "the generator found too few SOPs to be reading the real docs tree"
    assert entries.any? { |e| e.kind == :heartbeat }, "no heartbeat was registered"
    assert entries.any? { |e| e.owner == "Shared" }, "no shared module was registered"
  end

  # The reason the registry exists: Alex McRitchie says `clean-up` and the agent resolves it.
  test "[unit] clean-up resolves end to end" do
    row = SopRegistry.entries(ROOT).find { |e| e.invocation == "clean-up" }

    refute_nil row, "`clean-up` is not in the SOP registry"
    assert_equal "Mason", row.owner
    assert_path_exists Rails.root.join(row.path)
    assert_includes Rails.root.join(SopRegistry::REGISTRY_PATH).read,
                    "| `clean-up` | Mason | `mcritchie-studio/docs/agents/agents/mason/sops/clean-up.md` |"
  end

  # [integration] The accountability chart (rulings 2026-10-28) moved two SOPs: the
  # month close to Mack, the CFO, and ship-clock to Mason, the COO. The generator, the
  # committed table (installed as AGENTS.md) and each seat's chart owner agree.
  test "[integration] the registry names mack for close-the-month and mason for ship-clock, as the chart does" do
    rows = SopRegistry.entries(ROOT).to_h { |e| [e.invocation, e] }
    table = Rails.root.join(SopRegistry::REGISTRY_PATH).read
    chart = AccountabilityChart.load

    {
      "close-the-month" => ["Mack", "docs/agents/agents/mack/sops/close-the-month.md", "finance-admin", "mack"],
      "ship-clock" => ["Mason", "docs/agents/agents/mason/sops/ship-clock.md", "operations", "mason"],
      "Mack Heartbeat" => ["Mack", "docs/agents/agents/mack/HEARTBEAT.md", "finance-admin", "mack"]
    }.each do |invocation, (owner, path, seat, soul)|
      row = rows.fetch(invocation) { flunk "`#{invocation}` is not in the SOP registry" }
      assert_equal [owner, path], [row.owner, row.path]
      assert_path_exists Rails.root.join(path)
      assert_includes table, "| `#{invocation}` | #{owner} | `mcritchie-studio/#{path}` |"
      assert_equal soul, chart.seat(seat).owner, "the #{seat} seat's owner holds #{invocation}"
    end
    refute_includes table, "docs/agents/modules/close-the-month.md", "the shared copy is gone"
    refute_includes table, "docs/agents/agents/alex/sops/ship-clock.md", "ship-clock left Alex"
    assert_match(/close-the-month.*\bon the 5th\b/m, Rails.root.join("docs/agents/agents/mack/HEARTBEAT.md").read,
                 "Mack's heartbeat runs the monthly close on the 5th")
  end

  test "[unit] a soul's files register by location, a module only by its marker" do
    with_tree(
      "agents/turf_monster/HEARTBEAT.md" => "# Turf Monster Heartbeat\n",
      "agents/turf_monster/sops/score-watch.md" => "# Score Watch\n<!-- registry: live scores -->\n",
      "agents/carl/sops/review-primary.md" => "# Review Primary\n<!-- registry (role SOP): the primary's steps -->\n",
      "agents/carl/sops/plain.md" => "# Plain\n",
      "modules/shared-act.md" => "# Shared Act\n<!-- registry: a shared primitive -->\n",
      "modules/not-an-sop.md" => "# Not An SOP\n"
    ) do |root|
      rows = SopRegistry.entries(root).to_h { |e| [e.invocation, e] }

      assert_equal ["plain", "review-primary", "Turf Monster Heartbeat", "score-watch", "shared-act"], rows.keys
      assert_equal "Turf Monster", rows.fetch("score-watch").owner
      assert_equal "live scores", rows.fetch("score-watch").summary
      assert_equal "role SOP", rows.fetch("review-primary").note
      assert_nil rows.fetch("plain").summary, "a soul SOP needs no marker"
      assert_equal "Shared", rows.fetch("shared-act").owner
      refute rows.key?("not-an-sop"), "a module without the marker is not an SOP"
    end
  end

  test "[unit] the tables render each entry with its invocation, owner, note and summary" do
    with_tree(
      "agents/carl/HEARTBEAT.md" => "# Carl Heartbeat\n",
      "agents/carl/sops/review-primary.md" => "# Review Primary\n<!-- registry (role SOP): the primary's steps -->\n",
      "modules/shared-act.md" => "# Shared Act\n<!-- registry: a shared primitive -->\n"
    ) do |root|
      entries = SopRegistry.entries(root)
      registry = SopRegistry.registry_table(entries)
      start_here = SopRegistry.start_here_table(entries)

      assert_includes registry, "| `review-primary` (role SOP) | Carl | `mcritchie-studio/docs/agents/agents/carl/sops/review-primary.md` |"
      assert_includes registry, "| `Carl Heartbeat` | Carl | `mcritchie-studio/docs/agents/agents/carl/HEARTBEAT.md` |"
      assert_includes start_here, "| Carl `review-primary` SOP (the primary's steps) |"
      assert_includes start_here, "| `Carl Heartbeat` launcher |"
      assert_includes start_here, "| `shared-act` (a shared primitive) |"
    end
  end

  test "[unit] a new SOP file makes the committed block stale until --write" do
    with_tree("agents/alex/sops/clean-up.md" => "# Clean Up\n") do |root|
      SopRegistry.write!(root)
      assert_empty SopRegistry.stale(root)

      File.write(File.join(root, "docs/agents/agents/alex/sops/new-act.md"), "# New Act\n")
      assert_equal [SopRegistry::REGISTRY_PATH, SopRegistry::START_HERE_PATH], SopRegistry.stale(root)

      SopRegistry.write!(root)
      assert_includes File.read(File.join(root, SopRegistry::REGISTRY_PATH)), "`new-act`"
    end
  end

  test "[unit] a doc that lost its generated block is refused, not silently unregistered" do
    error = assert_raises(ArgumentError) { SopRegistry.splice("# Index\n", "| table |", "docs/agents/index.md") }

    assert_match(/has no sop-registry block/, error.message)
  end

  # /stages/sop renders config/devops_vocabulary.yml. Its Assemble and Ship lanes must be
  # owned by the soul the registry names for the SOP each lane runs.
  test "the vocabulary's release lanes are owned by the registry's owner of their SOP" do
    owners = Devops::Vocabulary.lanes.to_h { |lane| [lane[:lane], lane[:owner]] }
    registry = SopRegistry.entries(ROOT).to_h { |e| [e.invocation, e.owner] }

    { "Assemble" => "qa-release", "Ship" => "production-deploy" }.each do |lane, sop|
      refute_nil registry[sop], "`#{sop}` is not in the SOP registry"
      assert_equal registry[sop], owners[lane],
                   "the #{lane} lane in config/devops_vocabulary.yml is owned by #{owners[lane].inspect}, " \
                   "but the registry gives `#{sop}` to #{registry[sop]}"
    end
  end

  private

  # A throwaway docs tree: `files` are paths under docs/agents/, plus the two generated
  # docs carrying empty blocks.
  def with_tree(files)
    Dir.mktmpdir do |root|
      files.each do |rel, body|
        path = File.join(root, "docs/agents", rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      block = "#{SopRegistry.begin_marker}\n#{SopRegistry.end_marker}\n"
      [SopRegistry::REGISTRY_PATH, SopRegistry::START_HERE_PATH].each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
        File.write(File.join(root, rel), "# Doc\n\n#{block}")
      end
      yield root
    end
  end
end
