module LinkTreeHelper
  def public_link_sections
    sections = [
      { title: "Studio", links: [
        { label: "Dashboard", href: dashboard_path, emoji: "📊", desc: "Overview + activity" },
        { label: "Agents", href: agents_path, emoji: "🦞", desc: "Meet the McRitchie agents" },
        { label: "Tasks", href: tasks_path, emoji: "✅", desc: "Task board" },
        { label: "News", href: news_index_path, emoji: "📰", desc: "News pipeline" },
        { label: "Content", href: contents_path, emoji: "🎬", desc: "Content pipeline" },
      ] },
      { title: "NFL", links: [
        { label: "NFL Hub", href: nfl_hub_path, emoji: "🏈", desc: "Rankings + grades" },
        { label: "2026 Season", href: games_season_path(2026), emoji: "📅", desc: "Schedule + results" },
      ] },
      { title: "Directory", links: [
        { label: "Teams", href: teams_path, emoji: "🛡️", desc: "All teams" },
        { label: "People", href: people_path, emoji: "👤", desc: "Players + staff" },
        { label: "Docs", href: docs_path, emoji: "📚", desc: "Documentation" },
      ] },
    ]

    if defined?(Satellite) && Satellite.active.any?
      sections << {
        title: "Apps",
        links: Satellite.active.map do |satellite|
          {
            label: satellite.display_name,
            href: satellite.url_for(logged_in: logged_in?),
            emoji: satellite.emoji.presence || "🛰️",
            target: "_blank",
          }
        end,
      }
    end

    sections
  end

  def admin_link_sections
    [
      { title: "On-chain", links: [
        { label: "Signing Console", href: admin_signing_requests_path, emoji: "⛓️", featured: true,
          desc: "Keyless multisig — build, sign in your own Phantom, broadcast. Durable-nonce ready." },
      ] },
      { title: "Site", links: [
        { label: "Theme", href: admin_theme_path, emoji: "🎨", desc: "Palette + dark mode" },
        { label: "Schema", href: admin_schema_path, emoji: "🗂️", desc: "DB schema browser" },
      ] },
      { title: "Ops", links: [
        { label: "Error logs", href: "/error_logs", emoji: "🚨", desc: "Captured errors" },
        { label: "Toast test", href: toast_test_path, emoji: "🔔", desc: "Notification harness" },
        { label: "TikTok connect", href: admin_tiktok_connect_path, emoji: "🎵", desc: "OAuth handshake" },
      ] },
      { title: "Data", links: [
        { label: "News workflow", href: workflow_news_index_path, emoji: "🛠️", desc: "Intake → conclude board" },
        { label: "Merge people", href: merge_people_path, emoji: "🔀", desc: "Resolve duplicate people" },
        { label: "Duplicates", href: duplicates_people_path, emoji: "👥", desc: "Duplicate candidates" },
      ] },
    ]
  end

  def sidebar_link_sections
    sections = public_link_sections
    sections + (admin? ? admin_link_sections.map { |section| section.merge(admin: true) } : [])
  end
end
