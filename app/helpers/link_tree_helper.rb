module LinkTreeHelper
  def public_link_sections
    sections = []

    # Session wall: Studio/NFL/Directory links show only to signed-in users.
    # The Apps section below stays public so anyone can reach the satellites.
    if logged_in?
      sections += [
        { title: "Studio", links: [
          { label: "Dashboard", href: dashboard_path, emoji: "📊", hover_emoji: "📈", desc: "Overview + activity" },
          { label: "Agents", href: agents_path, emoji: "🦞", hover_emoji: "🤝", desc: "Meet the McRitchie agents" },
          { label: "Builders", href: builders_path, emoji: "🏗️", hover_emoji: "🚀", desc: "Builder roster + commit pace" },
          { label: "Tasks", href: tasks_path, emoji: "✅", hover_emoji: "🚦", desc: "Task board" },
          { label: "News", href: news_index_path, emoji: "📰", hover_emoji: "🔎", desc: "News pipeline" },
          { label: "Content", href: contents_path, emoji: "🎬", hover_emoji: "✨", desc: "Content pipeline" },
        ] },
        { title: "NFL", links: [
          { label: "NFL Hub", href: nfl_hub_path, emoji: "🏈", hover_emoji: "📈", desc: "Rankings + grades" },
          { label: "2026 Season", href: games_season_path(2026), emoji: "📅", hover_emoji: "🏟️", desc: "Schedule + results" },
        ] },
        { title: "Directory", links: [
          { label: "Teams", href: teams_path, emoji: "🛡️", hover_emoji: "📋", desc: "All teams" },
          { label: "People", href: people_path, emoji: "👤", hover_emoji: "🪪", desc: "Players + staff" },
          { label: "Docs", href: docs_path, emoji: "📚", hover_emoji: "🔎", desc: "Documentation" },
        ] },
      ]
    end

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
    [
      { title: "Site", links: [
        { label: "Dashboard", href: admin_dashboard_path, emoji: "📊", hover_emoji: "🔬", desc: "Users + request logs" },
        { label: "Deployments", href: deployments_path, emoji: "🚀", hover_emoji: "📦", desc: "Deploy lane board" },
        { label: "Theme", href: admin_theme_path, emoji: "🎨", hover_emoji: "🌓", desc: "Palette + dark mode" },
        { label: "Design System", href: admin_style_path, emoji: "🎨", hover_emoji: "🧩", desc: "Theme · Modals · Tricks · Tasks" },
        { label: "Schema", href: admin_schema_path, emoji: "🗂️", hover_emoji: "🔎", desc: "DB schema browser" },
        { label: "Email images", href: admin_email_images_path, emoji: "🖼️", hover_emoji: "✉️", desc: "Manage transactional email banners" },
      ] },
      { title: "Ops", links: [
        { label: "Error logs", href: "/error_logs", emoji: "🚨", hover_emoji: "🔍", desc: "Captured errors" },
        { label: "Toast test", href: toast_test_path, emoji: "🔔", hover_emoji: "✨", desc: "Notification harness" },
        { label: "TikTok connect", href: admin_tiktok_connect_path, emoji: "🎵", hover_emoji: "🔐", desc: "OAuth handshake" },
        { label: "Activities", href: activities_agents_path, emoji: "🎭", hover_emoji: "🎬", desc: "Cross-session agent activity feed" },
      ] },
      { title: "On-chain", links: [
        { label: "Signing Console", href: admin_signing_requests_path, emoji: "⛓️", hover_emoji: "✍️", featured: true,
          desc: "Keyless multisig — build, sign in your own Phantom, broadcast. Durable-nonce ready." },
      ] },
      { title: "Data", links: [
        { label: "AI Builder Multiple", href: admin_ai_builder_multiple_path, emoji: "📈", hover_emoji: "🤖", desc: "GitHub public commit pace backtest" },
        { label: "News workflow", href: workflow_news_index_path, emoji: "🛠️", hover_emoji: "🧭", desc: "Intake → conclude board" },
        { label: "Merge people", href: merge_people_path, emoji: "🔀", hover_emoji: "✅", desc: "Resolve duplicate people" },
        { label: "Duplicates", href: duplicates_people_path, emoji: "👥", hover_emoji: "🧹", desc: "Duplicate candidates" },
      ] },
    ]
  end

  def sidebar_link_sections
    sections = public_link_sections
    admin? ? admin_link_sections.map { |section| section.merge(admin: true) } + sections : sections
  end

  private

  def satellite_hover_emoji(slug)
    {
      "turf-monster" => "👹",
      "tax-studio" => "🧾",
      "chain-ops" => "⚡"
    }.fetch(slug, "✨")
  end
end
