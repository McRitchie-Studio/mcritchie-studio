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
    sections = admin_link_sections.map { |section| section.merge(admin: true) } + sections if admin?
    visitor_link_sections + owner_link_sections + sections
  end

  # A signed-out visitor's way in, first in the sidebar. The navbar keeps only
  # the Build App button, so Log in lives here (Alex McRitchie, 2026-10-20;
  # /tasks/drop-hero-meet-alex). Nothing once signed in.
  def visitor_link_sections
    return [] if logged_in?

    [ { title: "Account", links: [ { label: Studio.sign_in_label, href: login_path, emoji: "🔑", hover_emoji: "👋", desc: "Pick up where you left off" } ] } ]
  end

  # An app owner's links, first in the sidebar: their app (or "Applications")
  # and its CTO (or "Agents"), counted from their own memberships, admins
  # included (AppOwnership.sidebar_links, docs/agents/system/app-owners.md).
  # Nothing for a visitor or a user who owns no app.
  def owner_link_sections
    return [] unless logged_in? && current_user

    links = AppOwnership.sidebar_links(current_user).map do |link|
      { label: link.label, href: link.href, emoji: link.emoji, hover_emoji: link.emoji, desc: nil }
    end
    links.any? ? [ { title: "Your apps", links: links } ] : []
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
      "tax-studio" => "🧾"
    }.fetch(slug, "✨")
  end
end
