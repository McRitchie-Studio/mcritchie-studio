# View helpers over the navigation registry (config/navigation.yml).
module NavigationHelper
  # The standard page title: one h1 recipe for every page that adopts
  # components/_page_header.
  PAGE_TITLE_CLASSES = "text-2xl md:text-3xl font-bold text-heading".freeze

  def page_title(text, **options)
    content_tag(:h1, text, **options, class: class_names(PAGE_TITLE_CLASSES, options[:class]))
  end

  # The items of one sub-nav as this viewer should see them on the page keyed
  # `current`: the admin entries drop out for a non-admin, then each item's own
  # only / except / hide_when_current rule applies.
  def sub_nav_entries(nav, current:)
    current = current.to_s
    Navigation.sub_nav(nav).items.filter_map do |item|
      next unless item.page.public? || admin?
      next unless item.shown_on?(current)

      { item: item, href: item.page.path(self), current: item.page.key == current,
        narrow_only: item.narrow_only_on&.include?(current) }
    end
  end

  # A sub-nav as the engine page header's links line (studio/_page_header `links:`):
  # the links a page keeps under its title. A back item is dropped, because the crumb
  # trail above the title already leads there.
  def sub_nav_links(nav, current:)
    sub_nav_entries(nav, current: current).filter_map do |entry|
      item = entry[:item]
      next if item.back

      label = item.icon && item.page.emoji ? "#{item.page.emoji} #{item.text}" : item.text
      { label: label, href: entry[:href], current: (entry[:current] ? "page" : nil), data: { test: item.test_id }.compact }
    end
  end

  # The board views as the engine page header's tabs (studio/_page_header `tabs:`): one
  # tab per board in config/navigation.yml's board_views, the current board marked with
  # aria-current="page" (Alex McRitchie 2026-11-06, docs/PAGE_HEADER.md "The four kinds
  # of control"). Unlike the old switcher buttons, the current board stays in the row:
  # a tab group shows where you are. Each tab keeps its stage count badges, from
  # `counts` or else the board's own load (@tasks_by_stage).
  def board_view_tabs(current:, counts: nil)
    current = current.to_s
    counts = (counts || (@tasks_by_stage || {}).transform_values(&:size)).with_indifferent_access
    Navigation.sub_nav(:board_views).items.filter_map do |item|
      next unless item.page.public? || admin?

      badges = item.badges.map do |stage|
        count = counts[stage].to_i
        tag.span(count, class: "page-header-tab-count", title: "#{count} #{stage}",
                        data: { stage: stage, count: count })
      end
      { label: safe_join([ item.text, *badges ], " "), href: item.page.path(self),
        current: (item.page.key == current ? "page" : nil),
        data: { test: "board-view-tab-#{item.page.key}" } }
    end
  end

  # The board views as quick links (studio/_page_header `menu:`), for a page that is
  # not itself a board, such as /stages.
  def board_view_menu
    Navigation.sub_nav(:board_views).items.filter_map do |item|
      next unless item.page.public? || admin?

      { label: item.text, href: item.page.path(self), data: { test: "board-view-link-#{item.page.key}" } }
    end
  end
end
