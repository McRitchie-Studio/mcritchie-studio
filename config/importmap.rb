# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "dropping_text"
pin "alex_chat"
pin "depth_chart"
# chart.js is the self-contained jsDelivr/esm.sh "auto" bundle (auto-registers
# controllers + scales, @kurkle/color inlined). chartkick is the ESM build,
# pinned to a UNIQUE filename so propshaft serves THIS file and not the chartkick
# gem's UMD vendor/assets/javascripts/chartkick.js (same basename → it would
# shadow ours, and that UMD build has no ESM default export → the import breaks).
pin "chart.js" # @4.5.1
pin "chartkick", to: "chartkick.esm.js" # @5.0.1
