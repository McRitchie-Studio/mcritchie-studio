# The page shell: the engine's navbar, and the one rule this app adds to it.
module ShellHelper
  # The engine navbar's brand: `<h1 class="nav-title …">…</h1>`. The classes
  # carry all of its styling, so the element name is free to change.
  BRAND_HEADING = %r{<h1(?<attributes>\s[^>]*\bnav-title\b[^>]*)>(?<brand>.*?)</h1>}m

  # Any h1 opening tag.
  PAGE_HEADING = /<h1[\s>]/

  # The engine's navbar (layouts/_navbar), with its link sidebar.
  #
  # A page has one h1. The engine draws the brand as an h1, which is right on a
  # page with no heading of its own; where the rendered page carries its own h1
  # (components/_page_header, or one written by hand) the brand is drawn as a
  # div with the same classes, so the page's title is the outline's only h1.
  #
  #   page_html  the rendered page body, as the layout's `yield` returns it
  def hub_navbar(page_html: nil)
    navbar = render("layouts/navbar", show_logout_link: true)
    page_heading?(page_html) ? brand_without_heading(navbar) : navbar
  end

  def page_heading?(page_html)
    page_html.to_s.match?(PAGE_HEADING)
  end

  # The navbar with its brand h1 redrawn as a div. The markup is the engine's own
  # rendered output, already safe, and only the element name changes.
  def brand_without_heading(navbar)
    navbar.to_str.sub(BRAND_HEADING) { "<div#{$~[:attributes]}>#{$~[:brand]}</div>" }.html_safe
  end
end
