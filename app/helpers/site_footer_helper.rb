# The facts every site footer prints: where the studio is, how to reach it, and
# the links a visitor (or a carrier reviewing an SMS registration) looks for at
# the bottom of a page. One hash, so the five candidate footers on /footers and
# the one that wins cannot disagree about an address or a phone number.
module SiteFooterHelper
  # The studio's Grasshopper line, the number its SMS registration names.
  SITE_FOOTER_PHONE = "(303) 222-2113".freeze

  def site_footer_facts
    {
      name: "McRitchie Studio",
      tagline: "Solutions for business, people, agents and families.",
      street: "3000 Lawrence St",
      city_line: "Denver, CO 80205",
      neighborhood: "RiNo · Five Points",
      phone: SITE_FOOTER_PHONE,
      phone_href: "tel:+1#{SITE_FOOTER_PHONE.delete('^0-9')}",
      email: "alex@mcritchie.studio",
      hours: "Mon–Fri · 9am–5pm MT",
      lat: 39.7614786,
      lng: -104.978957,
      directions_url: "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205",
      explore: [
        [ "Home", root_path ],
        [ "Packages", packages_path ],
        [ "Build an app", build_path ],
        [ "Meet Alex", "#{root_path}#about" ],
        [ "Say hi", login_path ]
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
