# frozen_string_literal: true

# The crumb trail over each admin page's title (studio-engine's studio/_page_header,
# docs/PAGE_HEADER.md) walks Studio.crumbs, the engine's one parent map. The hub draws
# it from config/navigation.yml, where each page names only its `parent`. to_prepare,
# so a development reload of the registry redraws it.
#
# A record's own page is not in the registry (the wall and the sidebars read it, and a
# record page is no nav entry), so the records that have child pages are drawn here,
# after the registry: a view names one with its keyword, as
# studio_crumbs(parent: :task, task: @task). Their labels are truncated, because on a
# phone the trail gives way to one link to the parent, and that link is the label.
Rails.application.config.to_prepare do
  Navigation.registry.draw_crumbs(Studio.crumbs).draw do
    page :task, ->(task:) { truncate(task.title, length: 40) }, ->(task:) { task_path(task.slug) },
         parent: :deployments
    page :content, ->(content:) { truncate(content.title, length: 40) }, ->(content:) { content_path(content.slug) },
         parent: :contents
    page :news, ->(news:) { truncate(news.title, length: 40) }, ->(news:) { news_path(news.slug) },
         parent: :news_index
    page :broadcast, ->(broadcast:) { truncate(broadcast.subject.presence || broadcast.slug, length: 40) },
         ->(broadcast:) { edit_broadcast_path(broadcast) }, parent: :broadcasts
  end
end
