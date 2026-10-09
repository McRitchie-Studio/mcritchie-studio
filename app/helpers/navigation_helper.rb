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
end
