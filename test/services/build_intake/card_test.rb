require "test_helper"

# [unit] The intake card Xan's answer offers (BuildIntake::Card): names, hex
# colours and text contrast are checked in code, unknown fields refuse the card,
# a failing item is dropped, and the stored copy is the normalized one.
class BuildIntakeCardTest < ActiveSupport::TestCase
  LIGHT = { "primary" => "#1d4ed8", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" }.freeze
  DARK = { "primary" => "#60a5fa", "accent" => "#fbbf24", "surface" => "#0f172a", "text" => "#f1f5f9" }.freeze

  def card(fields) = BuildIntake::Card.validate({ "kind" => "intake" }.merge(fields))

  def palette(name = "Harbor", light: LIGHT, dark: DARK) = { "name" => name, "light" => light, "dark" => dark }

  test "a CTO card keeps valid names, drops bad ones, and refuses an unknown portrait" do
    verdict = card("card" => "cto", "names" => [ "Nova", "Mary-Jane", "x", "Robert'); DROP", "O'Neil" ], "portrait" => "harbor")
    assert verdict.ok?
    assert_equal %w[Nova Mary-Jane], verdict.card["names"], "only the first three are read, and 'x' is too short"
    assert_equal 3, verdict.card["dropped"], "the short one and the two never read"
    assert_equal "harbor", verdict.card["portrait"]

    refute card("card" => "cto", "names" => [ "Nova" ], "portrait" => "pikachu").ok?
    refute card("card" => "cto", "names" => [ "1abc", "  " ]).ok?, "no valid name refuses the card"
    refute card("card" => "cto", "names" => "Nova").ok?, "names must be a list"
  end

  test "names are 2 to 24 letters with single separators" do
    ok = [ "Jo", "Ada Lovelace", "Zoë", "D'Arcy", "Jean-Luc", "Sam Jr." ]
    bad = [ "J", "A" * 25, "R2D2", "<script>", "Ada--Lee", "-Ada", "Ada'", nil, 42 ]
    ok.each { |n| assert BuildIntake::Card.cto_name(n), "#{n.inspect} should pass" }
    bad.each { |n| assert_nil BuildIntake::Card.cto_name(n), "#{n.inspect} should fail" }
    assert_equal "Ada Lovelace", BuildIntake::Card.cto_name("  Ada   Lovelace "), "whitespace is squished first"
  end

  test "a palette card normalizes hex and keeps only readable palettes" do
    short = { "primary" => "#12F", "accent" => "F59E0B", "surface" => "#FFF", "text" => "#111827" }
    verdict = card("card" => "palette", "palettes" => [ palette("Harbor", light: short), palette("Dim", light: LIGHT.merge("text" => "#cccccc")) ])
    assert verdict.ok?
    assert_equal 1, verdict.card["palettes"].size, "light text #ccc on white is under 4.5:1"
    kept = verdict.card["palettes"].first
    assert_equal({ "primary" => "#1122ff", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" }, kept["light"])
    assert_equal 1, verdict.card["dropped"]
  end

  test "contrast is checked in BOTH modes" do
    unreadable_dark = DARK.merge("text" => "#1e293b")
    verdict = BuildIntake::Card.palette(palette(dark: unreadable_dark))
    refute verdict.ok?
    assert_match(/dark text on surface/, verdict.reason)
    assert BuildIntake::Card.palette(palette).ok?
  end

  test "a palette must name exactly the four roles, as hex" do
    refute BuildIntake::Card.palette(palette(light: LIGHT.except("accent"))).ok?
    refute BuildIntake::Card.palette(palette(light: LIGHT.merge("shadow" => "#000000"))).ok?
    refute BuildIntake::Card.palette(palette(light: LIGHT.merge("primary" => "blue"))).ok?
    refute BuildIntake::Card.palette(palette(light: LIGHT.merge("primary" => "url(javascript:x)"))).ok?
    refute BuildIntake::Card.palette(palette.merge("css" => "body{}")).ok?, "unknown palette field"
    refute BuildIntake::Card.palette(palette("<b>x</b>")).ok?, "palette names are plain words"
    refute card("card" => "palette", "palettes" => [ palette(light: LIGHT.merge("text" => "#eeeeee")) ]).ok?,
           "a card left with no palette is refused"
  end

  test "an address card normalizes names and drops reserved or malformed ones" do
    verdict = card("card" => "address", "names" => [ "Taco Truck Map!", "admin", "a" ])
    assert verdict.ok?
    assert_equal [ "taco-truck-map" ], verdict.card["names"]
    assert_equal 2, verdict.card["dropped"]
    refute card("card" => "address", "names" => [ "www" ]).ok?
  end

  test "an idea card is bounded plain text with the idea required" do
    verdict = card("card" => "idea", "idea" => "A booking site\nfor groomers", "audience" => "dog groomers")
    assert verdict.ok?
    assert_equal({ "card" => "idea", "idea" => "A booking site for groomers", "audience" => "dog groomers" }, verdict.card)
    refute card("card" => "idea", "audience" => "groomers").ok?
    refute card("card" => "idea", "idea" => "x" * 281).ok?
    refute card("card" => "idea", "idea" => { "nested" => true }).ok?
  end

  test "unknown fields, kinds and cards are refused" do
    refute card("card" => "cto", "names" => [ "Nova" ], "subdomain" => "evil").ok?
    refute card("card" => "theme", "names" => [ "Nova" ]).ok?
    refute BuildIntake::Card.validate({ "kind" => "change", "card" => "cto", "names" => [ "Nova" ] }).ok?
    refute BuildIntake::Card.validate("not a hash").ok?
    assert_match(/unknown field/, card("card" => "idea", "idea" => "x", "cto_name" => "Nova").reason)
  end

  test "WCAG ratios match the reference values" do
    assert_equal 21.0, BuildIntake::Contrast.ratio("#000000", "#ffffff")
    assert_equal 1.0, BuildIntake::Contrast.ratio("#777777", "#777777")
    assert_in_delta 4.48, BuildIntake::Contrast.ratio("#777777", "#ffffff"), 0.01
    assert_nil BuildIntake::Contrast.normalize("#12345")
    assert_equal "#aabbcc", BuildIntake::Contrast.normalize("ABC")
  end

  test "record_from! stores a valid card on the message and refuses the rest as events" do
    message = AgentMessage.create!(channel: "web", external_id: "build:t:1", channel_ref: "build",
                                   thread_key: "web:build:#{'a' * 24}", soul_slug: "xan", content: "hi", status: "received")
    stored = BuildIntake::Card.record_from!(message, { "kind" => "intake", "card" => "cto", "names" => [ "Nova" ] })
    assert_equal({ "card" => "cto", "names" => [ "Nova" ] }, message.reload.intake_card)
    assert_equal stored, message.intake_card
    assert message.events.exists?(kind: "intake_card")

    assert_nil BuildIntake::Card.record_from!(message, { "kind" => "ask", "capability" => "board_status" })
    assert_equal "intake_refused", message.events.last.kind
    assert_equal({ "card" => "cto", "names" => [ "Nova" ] }, message.reload.intake_card, "a refused card changes nothing")
  end
end
