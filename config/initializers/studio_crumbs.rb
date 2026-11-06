# frozen_string_literal: true

# The crumb trail over each admin page's title (studio-engine's studio/_page_header,
# docs/PAGE_HEADER.md) walks Studio.crumbs, the engine's one parent map. The hub draws
# it from config/navigation.yml, where each page names only its `parent`. to_prepare,
# so a development reload of the registry redraws it.
Rails.application.config.to_prepare do
  Navigation.registry.draw_crumbs(Studio.crumbs)
end
