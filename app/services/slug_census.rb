# Read-only census of every `*_slug` column in the database: which table each
# one points at, and how many of its rows name a slug no target row holds.
#
# It feeds the slug freeze (epic platform-audit-refactors, piece 5b): a column
# with zero orphans can take a foreign key today; a column with orphans needs a
# cleanup first. Read-only by construction: every statement is a SELECT, no
# transaction is opened, and the whole run sits inside
# `ActiveRecord::Base.while_preventing_writes`, so a write raises instead of
# landing. `test/services/slug_census_test.rb` measures that over a full run.
#
# Sample values are withheld for targets that hold people (PERSONAL_TARGETS):
# a person's slug is their name.
class SlugCensus
  SLUG_COLUMN = /_slug\z/
  PERSONAL_TARGETS = %w[people users contacts].freeze
  SAMPLE_LIMIT = 5

  # Resolved columns that carry no foreign key, each with its reason. Every other
  # resolved column has one with ON UPDATE CASCADE, which
  # test/models/slug_foreign_keys_test.rb pins. A rename still rewrites these
  # through the parent's slug_children; only the database guarantee is missing.
  TEAMS_NOT_LOADED = "production holds no teams rows yet, and this column is filled by an import " \
                     "or a form before the teams import runs; constrain it once teams are loaded".freeze
  TURF_RECAP = "a game recap arrives from Turf Monster naming Turf's games and teams, " \
               "which the hub's games and teams tables do not hold".freeze
  UNCONSTRAINED = {
    "athletes.team_slug" => TEAMS_NOT_LOADED,
    "appearances.team_slug" => TEAMS_NOT_LOADED,
    "pff_stats.team_slug" => TEAMS_NOT_LOADED,
    "contents.game_slug" => TURF_RECAP,
    "contents.team_slug" => TURF_RECAP,
    "contents.rival_team_slug" => TURF_RECAP,
    "release_conductor_claims.release_slug" => "a new qa-release claims the sentinel `__forming__` " \
                                               "before its release row exists; release slugs never change"
  }.freeze

  Row = Struct.new(:table, :column, :target_table, :target_column, :via, :total, :filled, :orphans, :samples,
                   :samples_withheld, keyword_init: true) do
    def name = "#{table}.#{column}"
    def resolved? = via != :unresolved
    def target = resolved? ? "#{target_table}.#{target_column}" : "unresolved"
  end

  def initialize(connection: ActiveRecord::Base.connection, sample_limit: SAMPLE_LIMIT)
    @connection = connection
    @sample_limit = sample_limit
  end

  # Every `*_slug` column with its target and counts, sorted by table and column.
  def run
    ActiveRecord::Base.while_preventing_writes do
      slug_columns.map { |table, column| census(table, column) }
    end
  end

  # [[table, column], ...] for every string column ending in `_slug`.
  def slug_columns
    @connection.tables.sort.flat_map do |table|
      @connection.columns(table).map(&:name).grep(SLUG_COLUMN).sort.map { |c| [ table, c ] }
    end
  end

  # [target_table, target_column, via] where via is :belongs_to, :convention or :unresolved.
  def resolve(table, column)
    from_belongs_to(table, column) || from_convention(column) || [ nil, nil, :unresolved ]
  end

  def self.to_markdown(rows)
    lines = [ "| Column | Target | Via | Rows | Filled | Orphans | Sample orphans |", "|---|---|---|---:|---:|---:|---|" ]
    rows.each do |r|
      samples = r.samples_withheld ? "withheld (personal)" : r.samples.map { |s| "`#{s}`" }.join(", ")
      lines << "| `#{r.name}` | #{r.target} | #{r.via} | #{r.total} | #{r.filled} | #{r.orphans || "-"} | #{samples} |"
    end
    lines.join("\n")
  end

  private

  def census(table, column)
    target_table, target_column, via = resolve(table, column)
    counts = count(table, column, target_table, target_column)
    orphans = counts["orphans"]&.to_i
    personal = PERSONAL_TARGETS.include?(target_table)
    samples = orphans.to_i.positive? && !personal ? sample(table, column, target_table, target_column) : []
    Row.new(table:, column:, target_table:, target_column:, via:, total: counts["total"].to_i,
            filled: counts["filled"].to_i, orphans:, samples:, samples_withheld: personal && orphans.to_i.positive?)
  end

  def count(table, column, target_table, target_column)
    t = q_table(table)
    c = q_col(column)
    orphans = target_table ? ", COUNT(*) FILTER (WHERE #{c} IS NOT NULL AND NOT #{exists(target_table, target_column, column)}) AS orphans" : ""
    @connection.select_one("SELECT COUNT(*) AS total, COUNT(#{c}) AS filled#{orphans} FROM #{t} AS child", "SlugCensus")
  end

  def sample(table, column, target_table, target_column)
    c = q_col(column)
    @connection.select_values(<<~SQL.squish, "SlugCensus")
      SELECT DISTINCT #{c} FROM #{q_table(table)} AS child
      WHERE #{c} IS NOT NULL AND NOT #{exists(target_table, target_column, column)}
      ORDER BY #{c} LIMIT #{@sample_limit.to_i}
    SQL
  end

  def exists(target_table, target_column, column)
    "EXISTS (SELECT 1 FROM #{q_table(target_table)} AS target WHERE target.#{q_col(target_column)}::text = child.#{q_col(column)}::text)"
  end

  def from_belongs_to(table, column)
    model = model_for(table)
    return unless model

    reflection = model.reflect_on_all_associations(:belongs_to).find { |r| r.foreign_key.to_s == column }
    return unless reflection
    return [ nil, nil, :unresolved ] if reflection.polymorphic?

    target = reflection.klass
    pk = reflection.association_primary_key.to_s
    return unless @connection.table_exists?(target.table_name) && @connection.column_exists?(target.table_name, pk)

    [ target.table_name, pk, :belongs_to ]
  rescue NameError
    nil
  end

  # `home_team_slug` tries `home_teams`, then `teams`: the longest table name
  # the column's words end with that has a `slug` column.
  def from_convention(column)
    words = column.delete_suffix("_slug").split("_")
    words.each_index do |i|
      candidate = words[i..].join("_").pluralize
      return [ candidate, "slug", :convention ] if @connection.table_exists?(candidate) && @connection.column_exists?(candidate, "slug")
    end
    nil
  end

  def model_for(table)
    model = table.classify.safe_constantize
    model if model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class? && model.table_name == table
  end

  def q_table(name) = @connection.quote_table_name(name)
  def q_col(name) = @connection.quote_column_name(name)
end
