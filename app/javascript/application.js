// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "dropping_text"
import "alex_chat"
import "depth_chart"
import "base58"          // window.encodeBase58/decodeBase58 — load before wallet_provider
import "wallet_provider" // window.walletProvider (Phantom + Wallet Standard hub)

// Charts for /intelligence (task-development trends dashboard). chart.js is the
// self-contained jsDelivr/esm.sh "auto" bundle (controllers + scales already
// registered, @kurkle/color inlined). chartkick attaches window.Chartkick and
// fires a "chartkick:load" event; the chartkick view helper waits on that event,
// so the per-chart inline <script> tags init correctly even though this module
// (deferred, like all importmap modules) runs after the page HTML parses.
import Chart from "chart.js"
import Chartkick from "chartkick"

// Axis/legend text + gridlines that stay legible in BOTH light and dark themes
// (a mid slate reads on either background; the dashboard cards never override it).
Chart.defaults.color = "#94a3b8"
Chart.defaults.borderColor = "rgba(148, 163, 184, 0.18)"
Chart.defaults.font.family =
  "Montserrat, system-ui, sans-serif"

Chartkick.use(Chart)
