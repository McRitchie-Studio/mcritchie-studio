module ContentsHelper
  def content_stage_scheme(stage)
    case stage.to_s
    when "idea"     then "stage-fresh"
    when "hook"     then "stage-shaping"
    when "script"   then "stage-structured"
    when "assets"   then "stage-refined"
    when "assembly" then "stage-cohered"
    when "posted"   then "stage-shipped"
    when "reviewed" then "stage-closed"
    else "neutral"
    end
  end

  # A post's text as X draws it: hashtags, handles and links in X's blue, the
  # rest plain. Escaped FIRST, then marked up, so copy can never inject markup.
  X_BLUE = "#1d9bf0".freeze
  def x_post_markup(text)
    escaped = ERB::Util.html_escape(text.to_s)
    marked  = escaped.gsub(%r{(https?://\S+|[#@][A-Za-z0-9_]+)}) { %(<span style="color:#{X_BLUE}">#{Regexp.last_match(1)}</span>) }
    marked.html_safe # rubocop:disable Rails/OutputSafety -- escaped above; only our own span is added
  end

end
