# /websites helpers.
module WebsitesHelper
  STRICT_LOCALS = /\A\s*<%#\s*locals:\s*\((.*?)\)\s*%>/m

  # The locals among `wanted` that the engine's studio/_carousel accepts, so a
  # page can ask for a carousel option before every engine it runs on has it.
  # The partial declares strict locals (its `<%# locals: (...) %>` line), and a
  # local it does not declare raises. Today that is autoplay: and loop:
  # (studio-engine task carousel-autoplay-and-loop): once the engine that
  # declares them is installed, /websites autoplays with no hub change.
  #
  #   carousel_optional_locals(autoplay: 6, loop: true) # => {} on studio-engine 0.132
  def carousel_optional_locals(**wanted)
    declared = carousel_strict_locals
    return wanted if declared.nil? # no strict locals: the partial takes any local

    wanted.select { |name, _| carousel_declares?(declared, name) }
  end

  # The style the /websites Portfolio row asks studio/_carousel for: :cascade
  # (Alex McRitchie, 2026-11-08: the looping five-in-view 3D row, the engine lab's
  # third option) where the installed engine has it, else :spotlight.
  # The capability is the partial's own strict locals: visible: arrived with the
  # cascade style (studio-engine task carousel-cascade-style) and only a cascade
  # takes it, so an engine that declares it accepts style: :cascade. An engine
  # before it raises on :cascade, so the row keeps the spotlight there.
  # A partial with no strict locals line says nothing either way, so it keeps the
  # spotlight: asking an engine for a style it lacks raises.
  def portfolio_carousel_style
    declared = carousel_strict_locals
    declared && carousel_declares?(declared, :visible) ? :cascade : :spotlight
  end

  # The installed studio/_carousel's strict locals line, or nil without one.
  def carousel_strict_locals
    lookup_context.find_template("studio/carousel", [], true).source[STRICT_LOCALS, 1]
  end

  def carousel_declares?(declared, name)
    declared.match?(/(?:\A|[\s,(])#{Regexp.escape(name.to_s)}:/)
  end

  # The inline custom properties a portfolio card paints its shade and text
  # with: the app's palette (BuildGallery.palette_for, #rrggbb only) or the
  # Studio shade, and the shade: the panel at PORTFOLIO_SHADE_ALPHA.
  def portfolio_card_style(example)
    palette = example.palette || BuildGallery::PORTFOLIO_SHADE
    colours = BuildGallery::PALETTE_KEYS.map { |key| "--pc-#{key}: #{palette.fetch(key)}" }
    red, green, blue = palette.fetch("panel").delete("#").scan(/../).map { |pair| pair.to_i(16) }
    (colours + [ "--pc-shade: rgb(#{red} #{green} #{blue} / #{BuildGallery::PORTFOLIO_SHADE_ALPHA})" ]).join("; ")
  end
end
