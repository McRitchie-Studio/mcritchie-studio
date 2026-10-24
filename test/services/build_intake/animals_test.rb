require "test_helper"

# [unit] The CTO avatar bank (task cto-animal-avatar-bank): one hundred
# recolourable animal glyphs, drawn in the client's palette, sampled in sets
# that never repeat an animal.
class BuildIntakeAnimalsTest < ActiveSupport::TestCase
  Animals = BuildIntake::Animals

  PALETTE = {
    "light" => { "primary" => "#4F46E5", "accent" => "#F59E0B", "surface" => "#FFFFFF", "text" => "#111827" },
    "dark" => { "primary" => "#818CF8", "accent" => "#FBBF24", "surface" => "#0F172A", "text" => "#F8FAFC" }
  }.freeze
  # A hard theme: a pale primary and a yellow accent on white, a near-white primary on black.
  PALE = {
    "light" => { "primary" => "#FDE68A", "accent" => "#FFFF00", "surface" => "#FFFFFF", "text" => "#000000" },
    "dark" => { "primary" => "#F5F5F5", "accent" => "#111111", "surface" => "#000000", "text" => "#FFFFFF" }
  }.freeze

  test "[unit] the bank holds 100 distinct animals, each a vendored single-colour glyph" do
    assert_equal 100, Animals::IDS.size
    assert_equal Animals::IDS.uniq, Animals::IDS
    files = Dir[Animals::DIR.join("*.svg")].map { |path| File.basename(path, ".svg") }
    assert_equal Animals::IDS.sort, files.sort, "one file per id, no strays"
    Animals::IDS.each do |id|
      glyph = Animals.glyph(id)
      assert_includes glyph, "<path", id
      assert_includes glyph, %(fill="currentColor"), "#{id} takes its colour from the theme"
      refute_match(/#(?:\h{3}){1,2}\b(?!")|rgb\(/, glyph.gsub(/fill="#fff"/, ""), "#{id} hard-codes no colour")
    end
  end

  test "[unit] the licence and the list ride beside the files" do
    license = Animals::DIR.join("LICENSE").read
    assert_match(/MIT License/, license)
    assert_match(/Copyright \(c\) Microsoft Corporation/, license)
    readme = Animals::DIR.join("README.md").read
    assert_match(/fluentui-emoji/, readme)
    Animals::IDS.each { |id| assert_includes readme, "- `#{id}`", "the README lists #{id}" }
  end

  test "[unit] an avatar id is animal:<id> from the bank, nothing else" do
    assert Animals.avatar?("animal:fox")
    assert Animals.avatar?("animal:polar-bear")
    assert_equal "fox", Animals.id_of("animal:fox")
    [ nil, "", "fox", "animal:", "animal:pikachu", "harbor", "upload:abcdefgh12", "animal:fox ", "ANIMAL:fox" ].each do |value|
      refute Animals.avatar?(value), value.inspect
    end
    assert_equal "Polar bear", Animals.label("animal:polar-bear")
    assert_equal "T rex", Animals.label("animal:t-rex")
    assert_equal Animals.default_for("tok-1"), Animals.default_for("tok-1")
    assert Animals.avatar?(Animals.default_for("tok-1"))
  end

  test "[unit] a set is SET_SIZE animals with no repeats, led by the pick, and a new set avoids the one on screen" do
    50.times do
      set = Animals.sample
      assert_equal Animals::SET_SIZE, set.size
      assert_equal set.uniq, set
      assert set.all? { |value| Animals.avatar?(value) }
    end

    set = Animals.sample(keep: "animal:fox")
    assert_equal "animal:fox", set.first
    assert_equal 1, set.count("animal:fox")

    on_screen = Animals.sample(keep: "animal:fox")
    20.times do
      fresh = Animals.sample(keep: "animal:fox", except: on_screen)
      assert_equal "animal:fox", fresh.first, "the pick survives a new set"
      assert_empty fresh.drop(1) & on_screen, "nothing else repeats from the set on screen"
      assert_equal fresh.uniq, fresh
    end

    # With almost the whole bank on screen, the set still fills, still without repeats.
    everything = Animals.all.first(95)
    crowded = Animals.sample(except: everything)
    assert_equal Animals::SET_SIZE, crowded.size
    assert_equal crowded.uniq, crowded

    assert_equal Animals.sample(seed: "tok-1"), Animals.sample(seed: "tok-1"), "a seed repeats its set"
    refute_equal Animals.sample(seed: "tok-1"), Animals.sample(seed: "tok-2")
  end

  test "[unit] each avatar wears the palette: the roles rotate through the bank" do
    variants = Animals::IDS.first(4).map { |id| Animals.colors("animal:#{id}", PALETTE)["light"] }
    ant, badger, bat, bear = variants
    assert_equal Animals.mix("#FFFFFF", "#4F46E5", 0.16), ant["bg"], "primary on a primary tint"
    assert_equal Animals.mix("#FFFFFF", "#F59E0B", 0.2), badger["bg"], "accent on an accent tint"
    assert_equal "#4F46E5", bat["bg"], "the surface colour on a solid primary disc"
    assert_equal "#FFFFFF", bat["fg"]
    assert_equal Animals.mix("#FFFFFF", "#F59E0B", 0.24), bear["bg"], "primary on an accent tint"
    assert_equal "#4F46E5", bear["fg"]
    assert_equal 4, variants.map { |c| c["bg"] }.uniq.size, "neighbours in the bank look different"

    dark = Animals.colors("animal:bat", PALETTE)["dark"]
    assert_equal "#818CF8", dark["bg"], "the dark set draws from the palette's dark side"
  end

  test "[unit] every avatar reads at 3:1 on its disc, light and dark, even on a pale theme" do
    [ PALETTE, PALE, {} ].each do |palette|
      Animals.all.each do |avatar|
        Animals.colors(avatar, palette).each do |side, c|
          ratio = AppPalette.contrast(c["fg"], c["bg"])
          assert ratio >= Animals::MIN_CONTRAST, "#{avatar} #{side} on #{palette.dig('light', 'primary') || 'fallback'}: #{ratio.round(2)}"
        end
      end
    end
  end

  test "[unit] the inline drawing carries both sets as variables; the document swaps by colour scheme" do
    svg = Animals.inline_svg("animal:fox", PALETTE, css_class: "h-10 w-10", label: "Nova <3", data: { test: "x" })
    c = Animals.colors("animal:fox", PALETTE)
    assert_includes svg, %(class="cto-animal h-10 w-10")
    assert_includes svg, "--ava-fg-l:#{c['light']['fg']};--ava-bg-l:#{c['light']['bg']};--ava-fg-d:#{c['dark']['fg']};--ava-bg-d:#{c['dark']['bg']}"
    assert_includes svg, %(aria-label="Nova &lt;3"), "the label is escaped"
    assert_includes svg, %(data-test="x")
    assert_includes svg, %(fill="var(--ava-bg)")
    assert_includes Animals.inline_svg("animal:fox", PALETTE), %(aria-hidden="true")
    assert_nil Animals.inline_svg("harbor", PALETTE)

    doc = Animals.document("animal:fox", PALETTE)
    assert_includes doc, "@media (prefers-color-scheme: dark)"
    assert_includes doc, c["dark"]["bg"]
    assert_nil Animals.document("upload:abcdefgh12", PALETTE)
  end

  test "[unit] a glyph with its own ids gets fresh ones per copy" do
    one = Animals.inline_svg("animal:deer", PALETTE)
    two = Animals.inline_svg("animal:deer", PALETTE)
    ids = ->(svg) { svg.scan(/id="([^"]+)"/).flatten }
    refute_empty ids.call(one)
    assert_empty ids.call(one) & ids.call(two)
    ids.call(one).each { |id| assert_includes one, "url(##{id})" }
  end

  test "[unit] the card, the choice and storage accept an animal and still accept an older portrait key" do
    assert BuildIntake::Portraits.choosable?("animal:fox")
    assert BuildIntake::Portraits.choosable?("harbor")
    refute BuildIntake::Portraits.choosable?("animal:pikachu")
    assert BuildIntake::Portraits.storable?("animal:fox")
    assert BuildIntake::Card.validate({ "kind" => "intake", "card" => "cto", "names" => %w[Nova], "portrait" => "animal:fox" }).ok?
    refute BuildIntake::Card.validate({ "kind" => "intake", "card" => "cto", "names" => %w[Nova], "portrait" => "animal:pikachu" }).ok?
  end
end
