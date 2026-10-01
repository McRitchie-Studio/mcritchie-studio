# The facts the site footer prints: where the studio is, how to reach it, and
# the links a visitor (or a carrier reviewing an SMS registration) looks for at
# the bottom of a page.
module SiteFooterHelper
  # The studio's Grasshopper line, the number its SMS registration names.
  SITE_FOOTER_PHONE = "(303) 222-2113".freeze
  SITE_FOOTER_EMAIL = "team@mcritchie.studio".freeze

  # Controllers whose pages are the public site, signed in or not.
  SITE_FOOTER_PUBLIC_CONTROLLERS = %w[landing packages build contact_submissions].freeze

  # The footer is the public site's: a visitor (or a carrier) gets it on every
  # page, and the public pages keep it for a signed-in viewer too. Every other
  # signed-in page is a working surface (boards, queues, editors) and stays
  # full-height.
  def show_site_footer?
    !logged_in? || SITE_FOOTER_PUBLIC_CONTROLLERS.include?(controller_name)
  end

  # Where "Schedule a call" goes: the same Sprintful page the home page embeds.
  # One constant, so a move to another scheduler is a one-line change.
  SITE_FOOTER_SCHEDULE_URL = "https://on.sprintful.com/alex-mcritchie".freeze

  def site_footer_facts
    {
      name: "McRitchie Studio",
      tagline: "Software & Marketing Solutions",
      street: "3000 Lawrence St",
      city_line: "Denver, CO 80205",
      phone: SITE_FOOTER_PHONE,
      phone_href: "tel:+1#{SITE_FOOTER_PHONE.delete('^0-9')}",
      email: SITE_FOOTER_EMAIL,
      lat: 39.7614786,
      lng: -104.978957,
      directions_url: "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205",
      # /contact is a literal: the page is the SMS opt-in form, added by
      # /tasks/sms-opt-in-contact-page, whose route helper is `contact_form_path`.
      columns: [
        [ "Contact",   [ [ SITE_FOOTER_EMAIL, "mailto:#{SITE_FOOTER_EMAIL}" ], [ SITE_FOOTER_PHONE, "tel:+1#{SITE_FOOTER_PHONE.delete('^0-9')}" ],
                         [ "Contact", "/contact" ], [ "Schedule a call", SITE_FOOTER_SCHEDULE_URL ], [ "Say hi", login_path ] ] ],
        [ "Solutions", [ [ "Packages", packages_path ], [ "Build an app", build_path ] ] ],
        [ "Company",   [ [ "Home", root_path ], [ "Meet Alex", "#{root_path}#about" ] ] ],
        [ "Legal",     [ [ "Privacy Policy", privacy_path ], [ "Terms of Service", terms_path ] ] ]
      ],
      # [ label, icon, url ]. A nil url renders the icon unlinked: the handle
      # is not on record yet.
      social: [
        [ "LinkedIn", :linkedin, "https://www.linkedin.com/in/amcritchie/" ],
        [ "Instagram", :instagram, nil ],
        [ "X", :x, "https://x.com/mcritchiealex" ]
      ],
      legal: [
        [ "Privacy Policy", privacy_path ],
        [ "Terms of Service", terms_path ]
      ]
    }
  end
end
