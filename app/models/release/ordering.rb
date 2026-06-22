class Release
  # Producer-first member ordering for a release. Gems (producers) sort before
  # apps (consumers), and within that a task always sorts AFTER any task whose
  # slug appears in its `dependencies` — a small stable topological sort that
  # falls back to `position` for the deterministic base order.
  #
  # Why both rules: producer-first is the heuristic that publishes a gem before
  # the apps that consume it; `dependencies` is the explicit task-to-task edge
  # that nails sequencing the heuristic can't infer (e.g. one app waits on
  # another). When they agree (app depends on gem) the result is unchanged; when
  # a dependency is explicit it wins, because correctness beats the heuristic.
  module Ordering
    module_function

    # gem before app before unknown — lower sorts first.
    KIND_RANK = { gem: 0, app: 1, unknown: 2 }.freeze

    # Returns the tasks in producer-first, dependency-honoring order.
    def producer_first(tasks)
      tasks = tasks.to_a
      by_slug = tasks.index_by(&:slug)

      # Deterministic base order: kind, then position, then the input index so
      # equal keys keep their incoming order (stable).
      base = tasks.each_with_index.sort_by { |task, i| [kind_rank(task), task.position || 0, i] }.map(&:first)

      placed = []
      placed_slugs = {}
      pending = base.dup

      # Stable topological pass: repeatedly take the first base-ordered task
      # whose in-release dependencies are already placed. A dependency outside
      # the release can't be ordered here, so it doesn't hold a task back. If a
      # cycle (or otherwise unsatisfiable set) would stall, take the head so the
      # pass always terminates deterministically rather than looping forever.
      until pending.empty?
        index = pending.index do |task|
          Array(task.dependencies).all? { |dep| !by_slug.key?(dep) || placed_slugs[dep] }
        end
        index ||= 0

        task = pending.delete_at(index)
        placed << task
        placed_slugs[task.slug] = true
      end

      placed
    end

    def kind_rank(task)
      KIND_RANK.fetch(task.release_kind, 2)
    end
  end
end
