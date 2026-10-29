# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "dropping_text"
pin "alex_chat"
pin "agent_chat"
pin "build_chat"
pin "build_domain"
pin "cta_glow"
pin "build_status"
pin "build_shell"
pin "agent_shell"
pin "agent_reveal"
pin "chat_follow"
pin "typing_placeholder"
pin "cto_chat", to: "agent_chat.js" # the old name, kept import-compatible
pin "depth_chart"
pin "scroll_tab_stop"
pin "logo_gallery"
pin "gmail_admin_modal"
# The Drive card's Google Picker (app/views/integrations/_drive_picks.html.erb).
pin "drive_picker"
pin "logo_editor"
pin "logo_download"
pin "agent_setups"
# The chat composer's files (app/views/agent_chats/_attachments.html.erb).
pin "chat_attachments"
# The CTO chat usage meter's reset countdown (app/views/agent_chats/_tokens_bar.html.erb).
pin "usage_countdown"
# The app chat status card's live pill countdown (app/views/agent_chats/_devops_stages.html.erb).
pin "devops_countdown"
pin "dreams_filter"
# Build My App's launch panel (app/views/build/_launch.html.erb).
pin "build_launch"
# Turbo Stream action that opens an engine modal (BuildController#sign_in_to_launch).
pin "modal_stream"
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
pin "gallery_motion"
# The brand page's Motion tab (task logo-motion-presets; app/javascript/logo_motion.js). GSAP 3.13.0 with
# MorphSVGPlugin and CustomEase, free under GSAP's standard licence: the UMD builds from
# cdn.jsdelivr.net/npm/gsap@3.13.0/dist, vendored byte for byte (self-hosted, so the CSP's script-src 'self' covers
# them). They are pinned for their digested URLs only: logo_motion.js reads them from the import map and loads each
# as a classic <script> (a UMD build assigns window.window, a TypeError in a module), and only when a Motion tab is
# on the page, so none is preloaded.
pin "logo_motion"
pin "logo_motion_parts"
pin "logo_motion_presets", preload: false
pin "gsap", to: "gsap.min.js", preload: false # @3.13.0
pin "gsap_morph_svg", to: "gsap-morph-svg.min.js", preload: false # @3.13.0 MorphSVGPlugin
pin "gsap_custom_ease", to: "gsap-custom-ease.min.js", preload: false # @3.13.0 CustomEase
