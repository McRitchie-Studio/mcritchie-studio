module Admin::AiBuilderMultipleHelper
  def ai_multiple(value)
    value.present? ? "#{number_with_precision(value, precision: 2, strip_insignificant_zeros: true)}x" : "Incomplete"
  end

  def ai_decimal(value)
    value.present? ? number_with_precision(value, precision: 2, strip_insignificant_zeros: true) : "—"
  end

  def ai_count(value)
    number_with_delimiter(value.to_i)
  end

  def ai_date(value)
    value.present? ? value.to_date.strftime("%b %-d, %Y") : "—"
  end

  def ai_short_date(value)
    value.present? ? value.to_date.strftime("%b %-d") : "—"
  end

  def ai_commit_week_header(range)
    date = range.week_end_date.to_date
    safe_join(
      [
        content_tag(:span, ai_short_date(date), class: "block normal-case tracking-normal text-secondary"),
        (content_tag(:span, date.year, class: "block text-[10px] text-muted mt-0.5") unless date.year == Time.now.utc.year)
      ].compact
    )
  end

  def ai_coverage_percent(count, minimum)
    return 0 if minimum.to_i <= 0

    [(count.to_f / minimum.to_f * 100).round, 100].min
  end

  def ai_polyline_points(weeks, method_name, max_value)
    return "" if weeks.blank? || max_value.to_f <= 0

    denominator = [weeks.size - 1, 1].max
    weeks.each_with_index.filter_map do |week, index|
      value = week.public_send(method_name)
      next if value.blank?

      x = (index.to_f / denominator * 100).round(2)
      y = (96 - (value.to_f / max_value.to_f * 88)).clamp(4, 96).round(2)
      "#{x},#{y}"
    end.join(" ")
  end

  def ai_chart_max(weeks)
    values = weeks.flat_map do |week|
      [
        week.ai_builder_multiple,
        week.control_builder_multiple,
        week.difficulty_adjusted_ai_builder_multiple
      ]
    end.compact.map(&:to_f)

    [values.max || 1.0, 1.0].max
  end
end
