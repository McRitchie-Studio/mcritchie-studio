# frozen_string_literal: true

# One EPIC, read off the tasks that carry its handle (tasks.epic_slug). There is
# deliberately no Epic table (see Task::EPIC_SLUG): an epic exists exactly while at
# least one task names it, so this is a read model over Task and nothing else.
#
# Backs /epics (every epic, newest activity first) and the header of
# /epics/<slug>. The whole index is ONE grouped query — (epic, stage) buckets with
# their counts and time bounds — folded here in Ruby, so the page's cost does not
# grow with the number of epics.
#
# DONE means the work reached production: a `shipped` task, or an `archived` one
# that shipped first (it carries completed_at, which only the move to `shipped`
# stamps). An archived task that never shipped was dropped, not done, so it counts
# toward the total and not toward progress.
class EpicSummary
  attr_reader :slug, :counts_by_stage, :first_created_at, :last_activity_at, :last_shipped_at, :done_count

  def self.all
    rows = Task.where.not(epic_slug: nil).group(:epic_slug, :stage).pluck(
      :epic_slug, :stage,
      Arel.sql("COUNT(*)"),
      Arel.sql("MIN(tasks.created_at)"),
      Arel.sql("MAX(tasks.updated_at)"),
      Arel.sql("MAX(tasks.completed_at)"),
      Arel.sql("COUNT(tasks.completed_at)")
    )
    rows.group_by(&:first).map { |slug, buckets| from_buckets(slug, buckets) }
        .sort_by { |summary| [-summary.last_activity_at.to_f, summary.slug] }
  end

  # The summary for one epic, or nil when no task carries the handle. Normalized
  # through the same door as the `?epic=` filter, so /epics/DevOps-V3 finds the
  # tasks stamped `devops-v3`.
  def self.find(value)
    slug = Task.normalize_epic_slug(value)
    return nil unless slug

    all.find { |summary| summary.slug == slug }
  end

  def self.from_buckets(slug, buckets)
    counts = {}
    done = 0
    first_created = last_activity = last_shipped = nil
    buckets.each do |(_slug, stage, count, min_created, max_updated, max_completed, completed_count)|
      counts[stage] = count
      done += stage == "shipped" ? count : (stage == "archived" ? completed_count : 0)
      first_created = [first_created, min_created].compact.min
      last_activity = [last_activity, max_updated].compact.max
      last_shipped = [last_shipped, max_completed].compact.max
    end
    new(slug: slug, counts_by_stage: counts, done_count: done, first_created_at: first_created,
        last_activity_at: last_activity, last_shipped_at: last_shipped)
  end
  private_class_method :from_buckets

  def initialize(slug:, counts_by_stage:, done_count:, first_created_at:, last_activity_at:, last_shipped_at:)
    @slug = slug
    @counts_by_stage = counts_by_stage
    @done_count = done_count
    @first_created_at = first_created_at
    @last_activity_at = last_activity_at
    @last_shipped_at = last_shipped_at
  end

  def total
    counts_by_stage.values.sum
  end

  # Whole percent done, 0-100. Rounded DOWN so an epic reads 100 only when every
  # task is done — 99.6 percent is not a finished epic.
  def progress_percent
    return 0 if total.zero?

    (done_count * 100) / total
  end

  def complete?
    total.positive? && done_count == total
  end

  # The stages this epic has tasks in, in board order, with their counts.
  def stage_counts
    Task::STAGES.filter_map { |stage| [stage, counts_by_stage[stage]] if counts_by_stage[stage].to_i.positive? }
  end

  # First task created to last task shipped — the epic's span so far. Nil until
  # anything has shipped.
  def elapsed_seconds
    return nil unless first_created_at && last_shipped_at

    [last_shipped_at - first_created_at, 0].max
  end
end
