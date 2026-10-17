# The client CTO's colours on the page (docs/agents/system/client-cto.md): CSS
# custom properties for both modes, so a view tints itself with
# `rgb(var(--cto-primary) / 0.1)` and the `dark:` variant swaps the set.
#
#   <div style="<%= client_cto_palette_style(app_cto) %>" class="<%= ClientCtoHelper::PALETTE_SWITCH %> …">
module ClientCtoHelper
  # Picks the light or dark set by the page's mode (darkMode: 'class').
  PALETTE_SWITCH = "[--cto-primary:var(--cto-primary-light)] [--cto-accent:var(--cto-accent-light)] " \
                   "dark:[--cto-primary:var(--cto-primary-dark)] dark:[--cto-accent:var(--cto-accent-dark)]".freeze

  # Only validated #RRGGBB values reach the attribute (AppPalette.rgb_triplet), so
  # a stored value can never break out of it.
  def client_cto_palette_style(app_cto)
    return "" unless app_cto

    AppPalette::SIDES.flat_map do |side|
      colors = AppPalette.side(app_cto.palette, side)
      %w[primary accent].filter_map do |key|
        triplet = AppPalette.rgb_triplet(colors[key])
        "--cto-#{key}-#{side}: #{triplet};" if triplet
      end
    end.join(" ")
  end
end
