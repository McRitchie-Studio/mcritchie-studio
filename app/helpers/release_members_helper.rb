module ReleaseMembersHelper
  RELEASE_MEMBER_HIGHLIGHT_LIMIT = 2
  TASK_SIZE_WEIGHTS = {
    "small" => 1,
    "medium" => 2,
    "large" => 3,
    "xl" => 4
  }.freeze
  TASK_SIZE_LABELS = {
    "small" => "S",
    "medium" => "M",
    "large" => "L",
    "xl" => "XL"
  }.freeze

  # Current release cards show the two most expensive member tasks as readable
  # links, then summarize the remaining members by app/repo emoji.
  def release_member_condensed_summary(members, highlight_limit: RELEASE_MEMBER_HIGHLIGHT_LIMIT)
    members = Array(members)
    highlights = release_member_highlights(members, limit: highlight_limit)
    remaining = members.reject { |task| highlights.include?(task) }

    {
      highlights: highlights,
      repo_counts: release_member_repo_counts(remaining)
    }
  end

  def release_member_highlights(members, limit: RELEASE_MEMBER_HIGHLIGHT_LIMIT)
    members = Array(members)
    return members if members.size <= limit + 1 && members.none? { |task| release_member_expense_known?(task) }

    members.each_with_index
           .sort_by { |task, index| release_member_expense_sort_key(task, index) }
           .first(limit)
           .map(&:first)
  end

  def release_member_repo_counts(tasks)
    Array(tasks).each_with_object({}) do |task, counts|
      task.devops_repositories.each do |repo|
        emoji = app_emoji(repo)
        next if emoji.blank?

        counts[emoji] ||= { emoji: emoji, count: 0, repositories: [] }
        counts[emoji][:count] += 1
        counts[emoji][:repositories] << repo unless counts[emoji][:repositories].include?(repo)
      end
    end.values
  end

  # WORK WAITING FOR THE NEXT SWEEP, per app — the Releases summary card's "Next" row
  # when no candidate is open. Same shape as #release_member_repo_counts, so one
  # cluster partial draws both.
  #
  # Read off the ladder cards the page already built (Card#parked_at("accepted")), not
  # a second query: it is then the very count each app card in the Applications
  # sidebar prints on its `accepted` node, and the two cannot disagree. Largest
  # first; ties keep the ladder's order.
  def release_queued_repo_counts(cards)
    Array(cards).each_with_index.filter_map do |card, index|
      count = card.parked_at("accepted")
      emoji = app_emoji(card.repo)
      next if count.zero? || emoji.blank?

      [{ emoji: emoji, count: count, repositories: [card.repo] }, index]
    end.sort_by { |entry, index| [-entry[:count], index] }.map(&:first)
  end

  def release_member_expense_weight(task)
    size = release_member_size(task)
    TASK_SIZE_WEIGHTS.fetch(size.to_s, 0)
  end

  def release_member_expense_known?(task)
    task.total_cost.to_d.positive? || release_member_expense_weight(task).positive?
  end

  def release_member_expense_sort_key(task, index)
    cost = task.total_cost
    return [0, -cost.to_f, index] if cost.to_d.positive?

    [1, -release_member_expense_weight(task), index]
  end

  def release_member_cost_label(task)
    cost = task.total_cost
    return release_member_money_label(cost) if cost.to_d.positive?

    TASK_SIZE_LABELS[release_member_size(task).to_s]
  end

  def release_member_cost_title(task)
    cost = task.total_cost
    return "Measured task cost: #{release_member_money_label(cost)}" if cost.to_d.positive?

    size = release_member_size(task)
    size.present? ? "Estimated task size: #{size.upcase}" : "Task cost not measured"
  end

  def release_member_size(task)
    [task.actual_size, task.dev_size, task.po_size].find(&:present?)
  end

  def release_member_money_label(cost)
    value = cost.to_f
    return "$0.00" if value < 0.001

    value < 1 ? format("$%.4f", value) : format("$%.2f", value)
  end
end
