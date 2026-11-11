# The page shell: the engine's navbar, and the one rule this app adds to it.
module ShellHelper
  # Any main opening tag.
  PAGE_MAIN = /<main[\s>]/

  # The engine's navbar (layouts/_navbar), with its link sidebar.
  #
  # A page has one h1. The engine decides it (studio-engine 0.136.0,
  # StudioNavbarHelper#studio_page_has_h1?): the brand is the h1 on a page with
  # no heading of its own, and a div with the same classes where the rendered
  # page carries one (studio/_page_header, or one written by hand), so the
  # page's title is the outline's only h1. The hub passes no brand_heading.
  #
  # Signed in, the engine's icon slot carries what a phone's bar needs
  # (layouts/_navbar_phone_account). No Log out link: the link sidebar carries
  # it, and the navbar's copy put a second row under the name.
  #
  # An admin also gets the open admin login requests' notice in that slot, beside
  # the theme toggle and the gear, on every page (layouts/_navbar_login_notice).
  def hub_navbar
    phone_account = render("layouts/navbar_phone_account") if logged_in?
    render("layouts/navbar", extra_icons_html: safe_join([ navbar_login_notice, phone_account ].compact))
  end

  # The admin-only bell for open admin login requests, or nil when none waits.
  # One count query, for an admin only; nobody else pays for it.
  def navbar_login_notice
    return nil unless logged_in? && admin?

    count = awaiting_admin_logins.size
    render("layouts/navbar_login_notice", count: count) if count.positive?
  end

  # The open admin login requests, read once per request: the board's rows
  # (agent_login_requests/_pending) and the navbar notice share it. Admin only.
  def awaiting_admin_logins
    return [] unless admin?

    @awaiting_admin_logins ||= AgentLoginRequest.awaiting.to_a
  end

  # The engine's switch (components/_user_nav): the name and avatar open the
  # link sidebar, as the gear does, rather than going to /profile. The sidebar
  # opens on "You › Profile", so the account page is one click further, and the
  # three controls at the bar's right end all do one thing.
  def studio_account_opens_sidebar? = true

  # The layout wraps the page in the document's one <main> (axe
  # landmark-one-main). A page that renders its own <main> already has it, and
  # a second would be a duplicate landmark, so the layout leaves it unwrapped.
  def page_main?(page_html)
    page_html.to_s.match?(PAGE_MAIN)
  end
end
