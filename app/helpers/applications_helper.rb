# Helpers for /applications (ApplicationsController) and the app's tabbed page.
module ApplicationsHelper
  # The app page's tabs, in order (Alex McRitchie 2026-11-07, task app-page-tabs):
  # Overview | Pipeline | Chat, each its own URL. All three share one header
  # (applications/_page_header).
  APP_PAGE_TABS = %i[overview pipeline chat].freeze

  # Where clicking an app on /applications goes: its Overview tab.
  def app_todos_path(app)
    application_path(app.slug)
  end

  # The tabs this viewer gets for this app. The Pipeline tab is hidden from an
  # owner of an AppCatalog::UNANNOUNCED app, for whom the pipeline is a 404; an
  # admin sees it on every app. Chat is always a tab: an app with no CTO yet
  # answers it with its no-CTO state (CtoChatsController#show).
  def app_page_tab_keys(app, admin:)
    APP_PAGE_TABS.reject { |key| key == :pipeline && app_pipeline_hidden?(app, admin: admin) }
  end

  def app_pipeline_hidden?(app, admin:)
    !admin && AppCatalog::UNANNOUNCED.include?(app.slug)
  end

  # The tabs as studio/_page_header takes them, the `current` one marked.
  def app_page_tabs(app, admin:, current:)
    app_page_tab_keys(app, admin: admin).map do |key|
      { label: key.to_s.titleize, href: app_page_tab_path(app, key),
        current: (key == current ? "page" : nil), data: { test: "app-tab", tab: key } }
    end
  end

  def app_page_tab_path(app, key)
    case key
    when :overview then application_path(app.slug)
    when :pipeline then pipeline_application_path(app.slug)
    when :chat then chat_application_path(app.slug)
    else raise ArgumentError, "unknown app page tab #{key.inspect}"
    end
  end

  # The crumb trail over the app's title (studio-engine docs/PAGE_HEADER.md,
  # "Crumbs", the 2026-11-05 ruling): an admin's runs up the hub's parent map
  # (Admin Dashboard, Applications); an owner cannot open the admin dashboard,
  # so theirs is Applications alone.
  def app_page_crumbs(admin:)
    return studio_crumbs(parent: :applications) if admin

    [ { label: "Applications", href: applications_path } ]
  end
end
