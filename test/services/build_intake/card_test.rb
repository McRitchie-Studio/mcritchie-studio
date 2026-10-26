require "test_helper"

# [unit] The intake card Alex's answer offers (BuildIntake::Card): names, hex
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

  test "an idea card is a short title and two or three key features" do
    verdict = card("card" => "idea", "title" => "Groomer\nBooking  Hub", "features" => [ "Online booking", "SMS reminders", "", "Reviews", "Extra" ],
                   "idea" => "A booking site for groomers")
    assert verdict.ok?
    assert_equal({ "card" => "idea", "title" => "Groomer Booking Hub", "idea" => "A booking site for groomers",
                   "features" => [ "Online booking", "SMS reminders" ], "dropped" => 3 }, verdict.card,
                 "only the first three features are read; the blank one is dropped")

    refute card("card" => "idea", "features" => %w[a b]).ok?, "a title is required"
    refute card("card" => "idea", "title" => "Hub", "features" => %w[a b]).ok?, "one word is not a title"
    refute card("card" => "idea", "title" => "one two three four five six seven eight nine", "features" => %w[a b]).ok?
    refute card("card" => "idea", "title" => "Groomer Booking Hub", "features" => [ "Only one" ]).ok?, "needs two features"
    refute card("card" => "idea", "title" => "Groomer Booking Hub", "features" => "a, b").ok?, "features must be a list"
    refute card("card" => "idea", "title" => "Groomer Booking Hub", "features" => [ "x" * 81, "y" * 81 ]).ok?, "long features drop"
    refute card("card" => "idea", "title" => { "nested" => true }, "features" => %w[a b]).ok?
    assert_match(/unknown field/, card("card" => "idea", "title" => "A B", "features" => %w[a b], "audience" => "v1 field").reason,
                 "the v1 card's audience and day_one are no longer offered")
  end

  test "a summary card carries nothing; the page draws it from the request" do
    assert_equal({ "card" => "summary" }, card("card" => "summary").card)
    refute card("card" => "summary", "title" => "Injected").ok?
  end

  test "unknown fields, kinds and cards are refused" do
    refute card("card" => "cto", "names" => [ "Nova" ], "subdomain" => "evil").ok?
    refute card("card" => "theme", "names" => [ "Nova" ]).ok?
    refute BuildIntake::Card.validate({ "kind" => "change", "card" => "cto", "names" => [ "Nova" ] }).ok?
    refute BuildIntake::Card.validate("not a hash").ok?
    assert_match(/unknown field/, card("card" => "idea", "title" => "A B", "cto_name" => "Nova").reason)
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
                                   thread_key: "web:build:#{'a' * 24}", soul_slug: "alex", content: "hi", status: "received")
    stored = BuildIntake::Card.record_from!(message, { "kind" => "intake", "card" => "cto", "names" => [ "Nova" ] })
    assert_equal({ "card" => "cto", "names" => [ "Nova" ] }, message.reload.intake_card)
    assert_equal stored, message.intake_card
    assert message.events.exists?(kind: "intake_card")

    assert_nil BuildIntake::Card.record_from!(message, { "kind" => "ask", "capability" => "board_status" })
    assert_equal "intake_refused", message.events.last.kind
    assert_equal({ "card" => "cto", "names" => [ "Nova" ] }, message.reload.intake_card, "a refused card changes nothing")
  end

  test "once every step is set, an answer with no card gets the summary card from code" do
    request_row = AppRequest.create!(prompt: "A league site")
    message = AgentMessage.create!(channel: "web", external_id: "build:t:2", channel_ref: "build",
                                   thread_key: BuildIntake.thread_key(request_row.token), soul_slug: "alex", content: "hi", status: "received")
    assert_nil BuildIntake::Card.record_from!(message, nil), "an open step: no summary"

    request_row.update!(answers: { "idea" => "League", "title" => "League Standings Hub" }, cto_name: "Coach", cto_avatar: "harbor",
                        palette: { "name" => "Pitch", "light" => LIGHT, "dark" => DARK }, subdomain: "league-hub-#{SecureRandom.hex(2)}")
    assert_equal({ "card" => "summary" }, BuildIntake::Card.record_from!(message, nil))
    assert_equal "code", message.events.where(kind: "intake_card").last.detail["by"]
    assert_equal({ "card" => "summary" }, BuildIntake::Card.record_from!(message, { "kind" => "ask" }),
                 "a refused proposal still leaves the visitor the summary")

    stored = BuildIntake::Card.record_from!(message, { "kind" => "intake", "card" => "cto", "names" => [ "Nova" ] })
    assert_equal "cto", stored["card"], "a card Alex offered wins over the summary"
  end
end
