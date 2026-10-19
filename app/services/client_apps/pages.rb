# frozen_string_literal: true

module ClientApps
  # The shared host's own pages (ClientApps::Host): standalone HTML with inline
  # styles and no script, no hub layout, no asset from the hub's origin, and no
  # link back to it. Text is escaped; colours are taken only as #RRGGBB.
  module Pages
    DEFAULT_LIGHT = { "primary" => "#4F46E5", "accent" => "#F59E0B", "surface" => "#FFFFFF", "text" => "#111827" }.freeze
    DEFAULT_DARK = { "primary" => "#818CF8", "accent" => "#FBBF24", "surface" => "#0F172A", "text" => "#F1F5F9" }.freeze

    module_function

    def h(text) = ERB::Util.html_escape(text.to_s)

    def being_built(site)
      name = site.name.to_s.squish.presence || "Your app"
      cto = site.cto_name.to_s.squish.presence
      svg = site.portrait_svg
      portrait = if svg
                   %(<img class="portrait" alt="" src="data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}">)
                 else
                   %(<div class="portrait initial" aria-hidden="true">#{h((cto || name)[0].upcase)}</div>)
                 end
      who = cto ? "#{h(cto)}, its CTO, is on it." : "Its builder is on it."

      document(title: "#{name} is being built", style: palette_css(site), body: <<~HTML)
        <main class="card" data-client-app-state="being-built">
          #{portrait}
          <p class="eyebrow">Being built</p>
          <h1>#{h(name)}</h1>
          <p class="lede">This app is on its way. #{who} Check back soon.</p>
          <div class="bar" aria-hidden="true"><span></span></div>
        </main>
      HTML
    end

    def not_found
      document(title: "Not found", style: palette_css(nil), body: <<~HTML)
        <main class="card" data-client-app-state="not-found">
          <h1>Nothing here</h1>
          <p class="lede">There is no app at this address.</p>
        </main>
      HTML
    end

    def error
      document(title: "Something went wrong", style: palette_css(nil), body: <<~HTML)
        <main class="card" data-client-app-state="error">
          <h1>Something went wrong</h1>
          <p class="lede">Please try again in a moment.</p>
        </main>
      HTML
    end

    def palette_css(site)
      light = colours(site&.light, DEFAULT_LIGHT)
      dark = colours(site&.dark, DEFAULT_DARK)
      vars = ->(side) { side.map { |key, hex| "--#{key}: #{AppPalette.rgb_triplet(hex)};" }.join(" ") }
      ":root { #{vars.call(light)} } @media (prefers-color-scheme: dark) { :root { #{vars.call(dark)} } }"
    end

    # The side's four colours, each only when it is a #RRGGBB hex; the default
    # side's otherwise.
    def colours(side, fallback)
      side = side.is_a?(Hash) ? side : {}
      AppPalette::KEYS.to_h do |key|
        value = side[key].to_s.strip.upcase
        [ key, value.match?(AppPalette::HEX) ? value : fallback.fetch(key) ]
      end
    end

    def document(title:, style:, body:)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="robots" content="noindex">
          <title>#{h(title)}</title>
          <style>
            #{style}
            * { box-sizing: border-box; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 16px;
                   background: rgb(var(--surface)); color: rgb(var(--text));
                   font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
            .card { width: 100%; max-width: 420px; text-align: center; padding: 32px 24px; border-radius: 20px;
                    background: rgb(var(--primary) / 0.06); border: 1px solid rgb(var(--primary) / 0.18); }
            .portrait { width: 96px; height: 96px; border-radius: 50%; margin: 0 auto 16px; display: block;
                        box-shadow: 0 0 0 4px rgb(var(--primary) / 0.25); }
            .initial { display: grid; place-items: center; font-size: 40px; font-weight: 700;
                       background: rgb(var(--primary)); color: rgb(var(--surface)); }
            .eyebrow { margin: 0; font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase;
                       color: rgb(var(--primary)); font-weight: 600; }
            h1 { margin: 4px 0 8px; font-size: 28px; line-height: 1.2; overflow-wrap: anywhere; }
            .lede { margin: 0; opacity: 0.8; }
            .bar { margin: 24px auto 0; height: 6px; max-width: 200px; border-radius: 3px; overflow: hidden;
                   background: rgb(var(--primary) / 0.15); }
            .bar span { display: block; height: 100%; width: 40%; border-radius: 3px; background: rgb(var(--accent));
                        animation: slide 1.6s ease-in-out infinite; }
            @keyframes slide { 0% { transform: translateX(-100%); } 100% { transform: translateX(250%); } }
            @media (prefers-reduced-motion: reduce) { .bar span { animation: none; width: 100%; } }
          </style>
        </head>
        <body>
        #{body}
        </body>
        </html>
      HTML
    end
  end
end
