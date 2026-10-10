# The page shell: the engine's navbar, and the one rule this app adds to it.
module ShellHelper
  # Any h1 opening tag.
  PAGE_HEADING = /<h1[\s>]/

  # The engine's navbar (layouts/_navbar), with its link sidebar.
  #
  # A page has one h1. The engine draws the brand as an h1, which is right on a
  # page with no heading of its own; where the rendered page carries its own h1
  # (components/_page_header, or one written by hand) the brand is drawn as a
  # div with the same classes (brand_heading: false), so the page's title is the
  # outline's only h1.
  #
  # Signed in, the engine's icon slot carries what a phone's bar needs
  # (layouts/_navbar_phone_account).
  #
  #   page_html  the rendered page body, as the layout's `yield` returns it
  def hub_navbar(page_html: nil)
    phone_account = render("layouts/navbar_phone_account") if logged_in?
    render("layouts/navbar", show_logout_link: true, extra_icons_html: phone_account,
      brand_heading: !page_heading?(page_html))
  end

  def page_heading?(page_html)
    page_html.to_s.match?(PAGE_HEADING)
  end
end
