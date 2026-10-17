# A complete client CTO intake, as the /build intake (build-with-xan-intake)
# records it on the request, for AppLaunch, AppCto and the client_cto tests.
module ClientCtoFixtures
  PALETTE = {
    "light" => { "primary" => "#4F46E5", "accent" => "#F59E0B", "surface" => "#FFFFFF", "text" => "#111827" },
    "dark" => { "primary" => "#818CF8", "accent" => "#FBBF24", "surface" => "#0F172A", "text" => "#F8FAFC" }
  }.freeze

  ANSWERS = {
    "audience" => "Dog owners in Denver",
    "day_one" => "Book a grooming slot",
    "plan" => "A booking page for one groomer: pick a slot, pay a deposit, get a reminder."
  }.freeze

  def client_intake(**overrides)
    AppLaunch::Intake.new(**{ cto_name: "Nova", cto_avatar: "/build/portraits/portrait-03.webp",
                              palette: PALETTE.deep_dup, answers: ANSWERS.dup }.merge(overrides))
  end

  # A client app with its CTO, made directly (no launch).
  def client_app!(slug: "pawsome", name: "Pawsome", cto_name: "Nova")
    app = App.create!(slug: slug, name: name, emoji: "📱", color: PALETTE["light"]["primary"], package_tier: "vibe",
                      theme_colors: PALETTE)
    AppCto.create!(app: app, name: cto_name, portrait: "/build/portraits/portrait-03.webp", palette: PALETTE,
                   plan: ANSWERS["plan"], facts: { "owner" => "Pat", "audience" => ANSWERS["audience"] })
    app
  end
end
