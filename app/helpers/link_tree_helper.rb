# The link sidebar, /links and /admin/links, built from the navigation registry
# (config/navigation.yml). An entry shows when its page is public or the viewer
# is an admin, so a section holding only admin pages never reaches a visitor.
module LinkTreeHelper
  # The general sections, then the satellite apps.
  def public_link_sections
    sections = registry_link_sections(:general)

    if defined?(Satellite) && Satellite.active.any?
      sections << {
        title: "Apps",
        links: Satellite.active.map do |satellite|
          {
            label: satellite.display_name,
            href: satellite.url_for(logged_in: logged_in?),
            emoji: satellite.emoji.presence || "🛰️",
            hover_emoji: satellite_hover_emoji(satellite.slug),
            target: "_blank",
          }
        end,
      }
    end

    sections
  end

  def admin_link_sections
    registry_link_sections(:admin)
  end

  def sidebar_link_sections
    sections = public_link_sections
    admin? ? admin_link_sections.map { |section| section.merge(admin: true) } + sections : sections
  end

  private

  def registry_link_sections(group)
    Navigation.sidebar(group).filter_map do |section|
      links = section.pages.select { |page| page.public? || admin? }.map do |page|
        { label: page.label, href: page.path(self), emoji: page.emoji, hover_emoji: page.hover_emoji, desc: page.desc }
      end
      { title: section.title, links: links } if links.any?
    end
  end

  def satellite_hover_emoji(slug)
    {
      "turf-monster" => "👹",
      "tax-studio" => "🧾",
      "chain-ops" => "⚡"
    }.fetch(slug, "✨")
  end
end
