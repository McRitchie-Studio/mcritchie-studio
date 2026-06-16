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

  def builder_initials(builder)
    builder.display_name.split.map(&:first).first(2).join.upcase.presence || builder.github_login.first.upcase
  end
end
