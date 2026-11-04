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
    return visitor_sidebar_sections unless logged_in?

    sections = [ build_link_section ] + public_link_sections
    sections = admin_link_sections.map { |section| section.merge(admin: true) } + sections if admin?
    owner_link_sections + sections
  end

  # A signed-out visitor's way in, first in the sidebar. The navbar keeps only
  # the Build App button, so Sign In lives here (Alex McRitchie, 2026-10-20;
  # /tasks/drop-hero-meet-alex). Nothing once signed in.
  def visitor_link_sections
    return [] if logged_in?

    [ { title: "Account", links: [ { label: "Sign In", href: signin_path, emoji: "🔑", hover_emoji: "👋" } ] } ]
  end

  # /chat while it is open to visitors (AdminWall::PUBLIC holds it today); were it
  # ever closed, /build, where a visitor can already chat with Alex, instead of a
  # link that answers "Not authorized".
  def visitor_chat_path
    AdminWall::PUBLIC.fetch("chat", []).include?("index") ? chat_index_path : build_path
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

  # A signed-out visitor's sidebar: sign in, or start building (Alex McRitchie,
  # 2026-11-03). /links still lists the public pages.
  def visitor_sidebar_sections
    visitor_link_sections + [ build_link_section ]
  end

  # Chat and Portfolio, at every level (Alex McRitchie, 2026-11-04: "add Chat and
  # Portfolio to the logged in sidebar"). An admin is signed in, so an admin has them too.
  def build_link_section
    page = Navigation.page(:websites)
    { title: "Build", links: [
      { label: "Chat", href: visitor_chat_path, hover_emoji: "💬",
        emoji: safe_image_tag("/agents/alex.webp", alt: "", class: "w-5 h-5 rounded-full object-cover") },
      { label: page.label, href: page.path(self), emoji: page.emoji, hover_emoji: page.hover_emoji }
    ] }
  end

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
