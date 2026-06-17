module BuildersHelper
  def builder_week_header(range)
    date = range.week_end_date.to_date
    safe_join(
      [
        content_tag(:span, date.strftime("%b %-d"), class: "block normal-case tracking-normal text-secondary"),
        (content_tag(:span, date.year, class: "block text-[10px] text-muted mt-0.5") unless date.year == Time.now.utc.year)
      ].compact
    )
  end

  def builder_count(value)
    number_with_delimiter(value.to_i)
  end

  def builder_normalized_score_badge(score)
    return nil if score.blank?

    styles = {
      1 => "color: #fecaca; background: rgba(239, 68, 68, 0.16); border-color: rgba(239, 68, 68, 0.34);",
      2 => "color: #fed7aa; background: rgba(249, 115, 22, 0.16); border-color: rgba(249, 115, 22, 0.34);",
      3 => "color: #fde68a; background: rgba(234, 179, 8, 0.16); border-color: rgba(234, 179, 8, 0.34);",
      5 => "color: #d9f99d; background: rgba(132, 204, 22, 0.16); border-color: rgba(132, 204, 22, 0.34);",
      8 => "color: #bbf7d0; background: rgba(34, 197, 94, 0.16); border-color: rgba(34, 197, 94, 0.34);"
    }

    content_tag(
      :span,
      score,
      class: "ml-1 inline-flex h-5 min-w-5 items-center justify-center rounded px-1 text-[10px] font-bold leading-none border align-middle",
      style: styles.fetch(score.to_i, styles[1]),
      title: "Normalized score from this builder's five-year cached weekly history"
    )
  end

  def builder_initials(builder)
    builder.display_name.split.map(&:first).first(2).join.upcase.presence || builder.github_login.first.upcase
  end

  def builder_quarter_header(quarter)
    safe_join(
      [
        content_tag(:span, "Q#{quarter.quarter}", class: "block text-secondary"),
        content_tag(:span, quarter.year, class: "block text-[10px] text-muted mt-0.5")
      ]
    )
  end

  def builder_history_chart_color(index)
    hue = (index * 137.508).round(2) % 360
    "hsl(#{hue}, 72%, 62%)"
  end

  def builder_history_chart_points(row, quarters, max_value, width:, height:, padding_x:, padding_y:)
    return "" if quarters.blank?

    values = quarters.map { |quarter| row[:quarter_totals][quarter.key].to_i }
    drawable_width = width - (padding_x * 2)
    drawable_height = height - (padding_y * 2)
    x_step = quarters.size > 1 ? drawable_width.to_f / (quarters.size - 1) : 0

    values.each_with_index.map do |value, index|
      x = padding_x + (x_step * index)
      y = height - padding_y - ((value.to_f / max_value.to_f) * drawable_height)
      "#{x.round(2)},#{y.round(2)}"
    end.join(" ")
  end

  def builder_history_chart_x(quarters, index, width:, padding_x:)
    return width / 2.0 if quarters.size <= 1

    padding_x + (((width - (padding_x * 2)).to_f / (quarters.size - 1)) * index)
  end

  def builder_history_chart_y(value, max_value, height:, padding_y:)
    drawable_height = height - (padding_y * 2)
    height - padding_y - ((value.to_f / max_value.to_f) * drawable_height)
  end
end
