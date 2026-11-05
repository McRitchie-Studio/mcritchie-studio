# The link sidebar, /links and /admin/basement, built from the navigation registry
# (config/navigation.yml). An entry shows when its page is public or the viewer
# is an admin, so a section holding only admin pages never reaches a visitor.
module LinkTreeHelper
  # The general sections, then the satellite apps: /links for everyone, and the
  # Basement for an admin, with each app's description. They left the sidebar (Alex
  # McRitchie, 2026-11-04: "Lets move these all to the basement").
  def public_link_sections(desc: false)
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
            **(desc ? { desc: satellite.description } : {}),
          }
        end,
      }
    end

    sections
  end

  # /links: the Studio section, then the general sections and the apps.
  def links_page_sections
    [ studio_link_section(desc: true) ] + public_link_sections
  end

  def admin_link_sections
    registry_link_sections(:admin)
  end

  # The links kept off the sidebar: /admin/basement, for an admin only, though the
  # NFL pages and the apps stay public at /links. The view adds the engine's Geo row.
  def basement_link_sections
    return [] unless admin?

    registry_link_sections(:basement) + public_link_sections(desc: true)
  end

  def sidebar_link_sections
    return visitor_sidebar_sections unless logged_in?

    sections = [ studio_link_section ]
    sections = admin_link_sections.map { |section| section.merge(admin: true) } + sections if admin?
    owner_link_sections + sections
  end

  # A signed-out visitor's way in, first in the sidebar. The navbar keeps only
  # the Build App button, so Sign In lives here (Alex McRitchie, 2026-10-20;
  # /tasks/drop-hero-meet-alex). Nothing once signed in. It carries no header,
  # unlike the sections below it.
  def visitor_link_sections
    return [] if logged_in?

    [ { title: "Account", links: [ { label: "Sign In", href: signin_path, emoji: "🔑", hover_emoji: "👋", icon: "key-round" } ] } ]
  end

  # /chat while it is open to visitors (AdminWall::PUBLIC holds it today); were it
  # ever closed, /build, where a visitor can already chat with Alex, instead of a
  # link that answers "Not authorized".
  def visitor_chat_path
    AdminWall::PUBLIC.fetch("chat", []).include?("index") ? chat_index_path : build_path
  end

  # An app owner's links, first in the sidebar: at most two apps, then All N Apps,
  # counted from their own memberships, admins included (AppOwnership.sidebar_links,
  # docs/agents/system/app-owners.md). An app shows its CTO's portrait, and every row
  # swaps to a rocket on hover (Alex McRitchie, 2026-11-04). All apps is no app: it takes a
  # line icon under the glass sidebar, and an app row keeps its portrait and rocket. Nothing
  # for a visitor or a user who owns no app.
  def owner_link_sections
    return [] unless logged_in? && current_user

    links = AppOwnership.sidebar_links(current_user).map do |link|
      { label: link.label, href: link.href, emoji: owner_row_icon(link), hover_emoji: "🚀", desc: nil,
        **(link.kind == "apps" ? { icon: "layout-grid" } : {}) }
    end
    links.any? ? [ { title: "My Apps", header: true, links: links } ] : []
  end

  private

  # A row's small portrait: the Agent row's, else a client CTO's chosen one, else the
  # app's emoji when the app has no CTO or the CTO has no picture.
  def owner_row_icon(link)
    cto = link.cto
    css = "w-5 h-5 rounded-full object-cover"
    if cto&.agent&.avatar.present?
      safe_image_tag(cto.agent.avatar, alt: "", class: css)
    elsif cto&.client? && (drawn = cto_avatar_tag(cto.app_cto.portrait, cto.app_cto.palette, label: cto.display_name, css_class: css))
      drawn # nil for a portrait it does not know: this runs on every page, so that costs the emoji, not the page
    else
      link.emoji
    end
  end

  # A signed-out visitor's sidebar: sign in, or start building (Alex McRitchie,
  # 2026-11-03). /links still lists the public pages.
  def visitor_sidebar_sections
    visitor_link_sections + [ studio_link_section ]
  end

  # Build, Chat, Portfolio, Packages and Integrations, at every level (Alex McRitchie,
  # 2026-11-04: "change this to 'Studio' and have the first be Build"). Public on purpose:
  # Build is the funnel's front door and Packages is where customers compare the tiers.
  # One line each in the sidebar; /links has room for the descriptions.
  def studio_link_section(desc: false)
    row = lambda do |key|
      page = Navigation.page(key)
      { label: page.label, href: page.path(self), emoji: page.emoji, hover_emoji: page.hover_emoji, icon: page.icon, **(desc ? { desc: page.desc } : {}) }
    end
    chat = { label: "Chat", href: visitor_chat_path, hover_emoji: "💬", icon: "message-circle",
             emoji: safe_image_tag("/agents/alex.webp", alt: "", class: "w-5 h-5 rounded-full object-cover") }

    { title: "Studio", header: true, links: [ row.call(:build), chat, row.call(:websites), row.call(:packages), row.call(:integrations) ] }
  end

  def registry_link_sections(group)
    Navigation.sidebar(group).filter_map do |section|
      links = section.pages.select { |page| page.public? || admin? }.map do |page|
        { label: page.label, href: page.path(self), emoji: page.emoji, hover_emoji: page.hover_emoji, desc: page.desc, icon: page.icon }
      end
      { title: section.title, links: links, **(section.header ? { header: true } : {}) } if links.any?
    end
  end

  def satellite_hover_emoji(slug)
    {
      "turf-monster" => "👹",
      "tax-studio" => "🧾"
    }.fetch(slug, "✨")
  end
end
