# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "dropping_text"
pin "alex_chat"
pin "depth_chart"
pin "scroll_tab_stop"
# chart.js is the self-contained jsDelivr/esm.sh "auto" bundle (auto-registers
# controllers + scales, @kurkle/color inlined). chartkick is the ESM build,
# pinned to a UNIQUE filename so propshaft serves THIS file and not the chartkick
# gem's UMD vendor/assets/javascripts/chartkick.js (same basename → it would
# shadow ours, and that UMD build has no ESM default export → the import breaks).
pin "chart.js" # @4.5.1
pin "chartkick", to: "chartkick.esm.js" # @5.0.1
# The /deployments board effects and the elapsed ticker (app/javascript/board): pure
# modules (live_fx, release_fx, ticker, colors) and the *_dom modules that wire them to
# the page. The partials that need them import the *_dom entry.
pin_all_from "app/javascript/board", under: "board"
