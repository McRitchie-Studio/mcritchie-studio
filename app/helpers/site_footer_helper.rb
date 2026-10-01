# The facts the site footer prints: where the studio is, how to reach it, and
# the links a visitor (or a carrier reviewing an SMS registration) looks for at
# the bottom of a page.
module SiteFooterHelper
  SITE_FOOTER_EMAIL = "team@mcritchie.studio".freeze

  # Controllers whose pages are the public site, signed in or not.
  SITE_FOOTER_PUBLIC_CONTROLLERS = %w[landing packages build contact_submissions schedule].freeze

  # The footer is the public site's: a visitor (or a carrier) gets it on every
  # page, and the public pages keep it for a signed-in viewer too. Every other
  # signed-in page is a working surface (boards, queues, editors) and stays
  # full-height.
  def show_site_footer?
    !logged_in? || SITE_FOOTER_PUBLIC_CONTROLLERS.include?(controller_name)
  end

  def site_footer_facts
    {
      name: "McRitchie Studio",
      tagline: "Software & Marketing Solutions",
      street: "3000 Lawrence St",
      city_line: "Denver, CO 80205",
      email: SITE_FOOTER_EMAIL,
      lat: 39.7614786,
      lng: -104.978957,
      directions_url: "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205",
      # Contact is the SMS opt-in form. Its helper is `contact_form_path`;
      # `contact_path` belongs to the mailing list's /contacts/:id.
      columns: [
        [ "Contact",   [ [ SITE_FOOTER_EMAIL, "mailto:#{SITE_FOOTER_EMAIL}" ], [ "Schedule a call", schedule_index_path ],
                         [ "Contact", contact_form_path ] ] ],
        [ "Solutions", [ [ "Packages", packages_path ], [ "Build an app", build_path ] ] ],
        # Career has no page yet: a nil path renders the label disabled.
        [ "Company",   [ [ "Home", root_path ], [ "About", about_path ], [ "Career", nil ] ] ],
        [ "Legal",     [ [ "Privacy Policy", privacy_path ], [ "Terms of Service", terms_path ] ] ]
      ],
      # [ label, icon, url ]. A nil url renders the icon unlinked: the handle
      # is not on record yet.
      social: [
        [ "LinkedIn", :linkedin, "https://www.linkedin.com/in/amcritchie/" ],
        [ "Instagram", :instagram, "https://www.instagram.com/alexmcritchie/" ],
        [ "X", :x, "https://x.com/mcritchiealex" ]
      ],
      legal: [
        [ "Privacy Policy", privacy_path ],
        [ "Terms of Service", terms_path ]
      ]
    }
  end
end
