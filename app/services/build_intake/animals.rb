module BuildIntake
  # The CTO avatar bank (task cto-animal-avatar-bank, Alex McRitchie 2026-10-20): one
  # hundred animal glyphs the /build CTO card offers, each drawn in the client's
  # own theme. The glyphs are Microsoft's Fluent Emoji, High Contrast style (MIT),
  # one single-colour SVG per id under app/assets/images/cto_animals/; that
  # folder's README and LICENSE name the source, the licence and the list.
  #
  # THE AVATAR IS THE CONTRACT. app_requests.cto_avatar and app_ctos.portrait
  # store "animal:<id>", never a file name or a colour: the colours are worked
  # out at render time from the palette beside it, so a re-themed app re-colours
  # its CTO with no data change. The twelve older portrait keys
  # (BuildIntake::Portraits) still render for the apps that chose one.
  #
  # COLOURING. Each avatar is the glyph in one palette role on a disc of
  # another (#colors), for light and dark both. The roles rotate by the
  # animal's place in the bank, so any set mixes them and still wears the theme:
  # primary on a primary tint, accent on an accent tint, surface on a solid
  # primary disc, primary on an accent tint. The glyph is pulled toward the
  # theme's text colour until it reads at 3:1 on its disc (WCAG non-text).
  module Animals
    PREFIX = "animal:".freeze
    DIR = Rails.root.join("app/assets/images/cto_animals")
    # The bank, in a fixed order: an id's index picks its colour variant, so
    # reordering re-colours avatars. Append; never reorder.
    IDS = %w[
      ant badger bat bear beaver beetle bird bison blackbird pufferfish
      boar caterpillar butterfly camel cat chicken chipmunk cow cricket crocodile
      deer dodo dog dolphin donkey dove dragon duck eagle elephant
      sheep fish flamingo fox frog giraffe goat goose gorilla hamster
      hedgehog hippo bee horse jellyfish kangaroo koala ladybug leopard lion
      lizard llama mammoth monkey moose mouse octopus orangutan otter owl
      ox panda parrot peacock penguin phoenix pig polar-bear poodle rabbit
      raccoon ram rat rhino rooster sauropod scorpion seal shark skunk
      sloth snail snake spider swan t-rex tiger tropical-fish turkey turtle
      unicorn water-buffalo whale wolf zebra crab lobster shrimp squid oyster
    ].freeze
    # How many the picker shows at once: the twelve the portrait grid held.
    SET_SIZE = 12
    MIN_CONTRAST = 3.0
    # [glyph role, disc role, how much of the disc role tints the surface (1 = solid)].
    VARIANTS = [
      %w[primary primary] + [ 0.16 ],
      %w[accent accent] + [ 0.2 ],
      %w[surface primary] + [ 1.0 ],
      %w[primary accent] + [ 0.24 ]
    ].freeze
    # Used only when a palette is missing or partial (a draft before its theme).
    FALLBACK = { "primary" => "#4F46E5", "accent" => "#F59E0B", "surface" => "#FFFFFF", "text" => "#111827" }.freeze
    FALLBACK_DARK = { "primary" => "#818CF8", "accent" => "#FBBF24", "surface" => "#111827", "text" => "#F9FAFB" }.freeze

    module_function

    # "animal:fox" → "fox"; nil for anything else (a portrait key, an upload, junk).
    def id_of(value)
      text = value.to_s
      return nil unless text.start_with?(PREFIX)

      id = text.delete_prefix(PREFIX)
      IDS.include?(id) ? id : nil
    end

    def avatar?(value) = !id_of(value).nil?

    def avatar(id) = "#{PREFIX}#{id}"

    def all = IDS.map { |id| avatar(id) }

    # "animal:polar-bear" → "Polar bear".
    def label(value) = id_of(value).to_s.tr("-", " ").capitalize

    # A stable first pick for a request: the same visitor sees the same animal.
    def default_for(seed) = avatar(IDS[seed.to_s.sum % IDS.size])

    # A set of SIZE distinct avatars. KEEP (the visitor's current pick) leads it
    # when it is an animal, so a new set never loses the pick; the rest are drawn
    # from the bank minus EXCEPT (the set on screen) while enough remain, so a
    # "New set" shows new animals. SEED makes it repeatable (the first render).
    def sample(size: SET_SIZE, keep: nil, except: [], seed: nil)
      rng = seed.nil? ? Random.new : Random.new(seed.to_s.sum + seed.to_s.bytes.each_with_index.sum { |b, i| b * (i + 1) })
      kept = avatar?(keep) ? [ keep.to_s ] : []
      shown = Array(except).filter_map { |value| id_of(value) }
      pool = IDS.map { |id| avatar(id) } - kept
      fresh = pool.reject { |value| shown.include?(id_of(value)) }
      pool = fresh if fresh.size >= size - kept.size
      (kept + pool.shuffle(random: rng)).first(size)
    end

    # The glyph's inner markup (no <svg> wrapper), read once per id.
    def glyph(id)
      @glyphs ||= {}
      @glyphs[id] ||= DIR.join("#{id}.svg").read[%r{\A<svg[^>]*>(.*)</svg>\s*\z}m, 1].to_s.freeze
    end

    # { "light" => { "fg", "bg" }, "dark" => { "fg", "bg" } } for VALUE on PALETTE.
    def colors(value, palette)
      id = id_of(value) || IDS.first
      fg_role, bg_role, tint = VARIANTS[IDS.index(id) % VARIANTS.size]
      AppPalette::SIDES.to_h do |side|
        set = side_colors(palette, side)
        bg = tint >= 1 ? set[bg_role] : mix(set["surface"], set[bg_role], tint)
        [ side, { "fg" => legible(set[fg_role], bg, set["text"], set["surface"]), "bg" => bg } ]
      end
    end

    # The avatar as an inline <svg> for a page that toggles .dark on <html>: the
    # colours ride as CSS variables (the .cto-animal rule in
    # app/assets/tailwind/cto_animal.css swaps the set). CLASS sizes it; LABEL
    # is its accessible name (nil: decorative); DATA adds data-* attributes.
    def inline_svg(value, palette, css_class: nil, label: nil, data: {})
      id = id_of(value) or return nil
      c = colors(value, palette)
      style = "--ava-fg-l:#{c['light']['fg']};--ava-bg-l:#{c['light']['bg']};--ava-fg-d:#{c['dark']['fg']};--ava-bg-d:#{c['dark']['bg']}"
      a11y = label ? %(role="img" aria-label="#{ERB::Util.h(label)}") : %(aria-hidden="true")
      attrs = data.map { |key, val| %( data-#{ERB::Util.h(key.to_s.dasherize)}="#{ERB::Util.h(val)}") }.join
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" class="cto-animal #{ERB::Util.h(css_class)}" style="#{style}" #{a11y} data-animal="#{id}"#{attrs}>) +
        %(<circle cx="16" cy="16" r="16" fill="var(--ava-bg)"/>) +
        %(<g transform="translate(5.6 5.6) scale(0.65)" style="color:var(--ava-fg)">#{scoped(glyph(id))}</g></svg>)
    end

    # A standalone SVG document (an <img> or a data: URI on a page this app does
    # not style, e.g. ClientApps::Pages): the light set, and the dark one under
    # prefers-color-scheme.
    def document(value, palette)
      id = id_of(value) or return nil
      c = colors(value, palette)
      %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><style>) +
        %(.bg{fill:#{c['light']['bg']}}.fg{color:#{c['light']['fg']}}) +
        %(@media (prefers-color-scheme: dark){.bg{fill:#{c['dark']['bg']}}.fg{color:#{c['dark']['fg']}}}</style>) +
        %(<circle class="bg" cx="16" cy="16" r="16"/><g class="fg" transform="translate(5.6 5.6) scale(0.65)">#{glyph(id)}</g></svg>)
    end

    def side_colors(palette, side)
      base = side == "dark" ? FALLBACK_DARK : FALLBACK
      given = AppPalette.side(palette, side).select { |_, hex| hex.to_s.match?(AppPalette::HEX) }
      base.merge(given)
    end

    # FG, pulled toward TEXT (then SURFACE) in steps until it reads on BG.
    def legible(fg, bg, text, surface)
      [ text, surface ].each do |target|
        0.step(1.0, 0.2) do |amount|
          candidate = mix(fg, target, amount)
          return candidate if AppPalette.contrast(candidate, bg) >= MIN_CONTRAST
        end
      end
      AppPalette.contrast(text, bg) >= AppPalette.contrast(surface, bg) ? text : surface
    end

    # A blend of two #RRGGBB colours: AMOUNT of TWO into ONE.
    def mix(one, two, amount)
      a = one.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
      b = two.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
      "#" + a.zip(b).map { |x, y| format("%02X", (x + ((y - x) * amount)).round) }.join
    end

    # Ids inside a glyph (one mask, in deer) made unique per copy, so two inline
    # copies on one page never point at each other's (possibly hidden) defs.
    def scoped(markup)
      ids = markup.scan(/id="([^"]+)"/).flatten
      return markup if ids.empty?

      suffix = SecureRandom.alphanumeric(6)
      ids.reduce(markup) { |out, id| out.gsub(%(id="#{id}"), %(id="#{id}-#{suffix}")).gsub("url(##{id})", "url(##{id}-#{suffix})") }
    end
  end
end
