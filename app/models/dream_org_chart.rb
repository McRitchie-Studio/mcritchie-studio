# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_bank").to_s
require Rails.root.join("bin/lib/sop_registry").to_s

# The dream bank as an org chart, for the /dreams page: the platform dreams on top,
# then one column per soul with that soul's dreams grouped by stage and, under them,
# the soul's SOPs from the registry with a dream count each and the SOP's step
# dreams grouped by step.
#
# It reads the tracked files live through the two parsers the CLI uses
# (bin/lib/dream_bank.rb and bin/lib/sop_registry.rb). No table, no board.
#
# Placement rules:
#   - a dream with no `soul` and no `sop` tag is a platform dream;
#   - a step dream (`sop:` + `step:`, no soul) shows under its SOP, in whichever
#     column the registry places that SOP, grouped by step;
#   - a dream tagged with several souls shows under EACH of them, because each of
#     those souls' sequences loads it (bin/dream <soul>);
#   - within a column, dreams group by their first `stage` tag, and a dream with no
#     stage lands in the NO_STAGE bucket, so no dream is ever dropped;
#   - every status is shown (proposed included); the page filters by status.
#
# SOP counts come from a dream's `sop` tag only, over the whole bank: a step dream
# carries no soul, so it belongs to no column's own dreams. A zero marks where the
# bank is thin. There is deliberately no stage-to-SOP guess.
class DreamOrgChart
  PLATFORM = DreamBank::PLATFORM
  NO_STAGE = "no stage"
  STAGE_ORDER = %w[designed building submitted reviewed assembled shipped blocked].freeze
  APPROVED = DreamBank::APPROVED
  PROPOSED = "proposed"

  # dream_statuses: one status per tagged dream, so the page can count under a filter.
  # steps: the SOP's step dreams as StepGroups, in step-name order.
  Sop = Struct.new(:invocation, :kind, :doc_path, :summary, :dream_count, :dream_statuses, :steps, keyword_init: true)
  StageGroup = Struct.new(:stage, :dreams, keyword_init: true)
  StepGroup = Struct.new(:step, :dreams, keyword_init: true)
  Column = Struct.new(:slug, :name, :title, :avatar, :color, :stages, :sops, keyword_init: true) do
    def dreams = stages.flat_map(&:dreams)
    def sop_dream_total = sops.sum(&:dream_count)
  end

  attr_reader :platform, :columns, :dreams

  def self.build(root: Rails.root.to_s, dir: DreamBank.bank_dir, souls: DreamBank.roster)
    new(dreams: DreamBank.all(dir: dir), entries: SopRegistry.entries(root.to_s), souls: souls)
  end

  def initialize(dreams:, entries:, souls:)
    @dreams = Array(dreams)
    @souls = souls
    @entries = Array(entries)
    @platform = column(PLATFORM, { "name" => "Platform", "title" => "Loads at every session start" },
                       @dreams.select(&:platform?), shared_entries)
    @columns = soul_slugs.map do |slug|
      column(slug, @souls.fetch(slug, { "name" => slug.tr("-", " ").split.map(&:capitalize).join(" ") }),
             @dreams.select { |dream| souls_of(dream).include?(slug) }, soul_entries(slug))
    end
  end

  # { "all" => n, "approved" => n, "proposed" => n } over the distinct dream files.
  def counts
    { "all" => @dreams.size,
      APPROVED => @dreams.count { |dream| dream.status == APPROVED },
      PROPOSED => @dreams.count { |dream| dream.status == PROPOSED } }
  end

  # The docs viewer path (DocsController, rooted at docs/agents) of a dream's file.
  def self.doc_path_for(dream)
    [ "dreams", dream.home.presence, dream.slug ].compact.join("/")
  end

  private

  # Roster souls in position order, then any soul a dream or an SOP directory names
  # that the roster does not, so nothing in the bank is left off the chart.
  def soul_slugs
    rostered = @souls.sort_by { |slug, record| [ record["position"] || Float::INFINITY, slug ] }.map(&:first)
    tagged = @dreams.flat_map { |dream| souls_of(dream) }
    owners = @entries.filter_map { |entry| soul_dir(entry) }
    (rostered + tagged + owners).uniq
  end

  def souls_of(dream) = dream.souls.map { |soul| DreamBank.canonical_soul(soul) }

  # The canonical soul slug an entry's directory names (turf_monster -> turf-monster,
  # ray/xan -> alex), or nil for a shared module.
  def soul_dir(entry)
    match = %r{\Adocs/agents/agents/([^/]+)/}.match(entry.path)
    match && DreamBank.canonical_soul(match[1])
  end

  def soul_entries(slug) = @entries.select { |entry| soul_dir(entry) == slug }

  def shared_entries = @entries.reject { |entry| soul_dir(entry) }

  def column(slug, record, dreams, entries)
    Column.new(slug: slug, name: record["name"], title: record["title"], avatar: record["avatar"],
               color: record["color"], stages: stage_groups(dreams), sops: sops(entries))
  end

  def stage_groups(dreams)
    dreams.group_by { |dream| dream.tags.fetch("stage", []).first || NO_STAGE }
          .sort_by { |stage, _| [ stage == NO_STAGE ? 1 : 0, STAGE_ORDER.index(stage) || STAGE_ORDER.size, stage ] }
          .map { |stage, grouped| StageGroup.new(stage: stage, dreams: grouped) }
  end

  def sops(entries)
    entries.map do |entry|
      tagged = @dreams.select { |dream| dream.tags.fetch("sop", []).include?(entry.invocation) }
      Sop.new(invocation: entry.invocation, kind: entry.kind, summary: entry.summary,
              doc_path: entry.path.delete_prefix("docs/agents/").delete_suffix(".md"),
              dream_count: tagged.size, dream_statuses: tagged.map(&:status), steps: step_groups(tagged))
    end
  end

  def step_groups(dreams)
    dreams.select { |dream| dream.tags.fetch("step", []).any? }
          .group_by { |dream| dream.tags["step"].first }
          .sort_by(&:first)
          .map { |step, grouped| StepGroup.new(step: step, dreams: grouped) }
  end
end
