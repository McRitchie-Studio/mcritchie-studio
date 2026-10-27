// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "dropping_text"
import "alex_chat"
// The shared agent web chat (first page: /applications/:slug/chat): delegated listeners, inert on every other page.
import "agent_chat"
// The /build chat with Alex: polls for answers while one is pending, inert on every other page.
import "build_chat"
// The /build agent shell: the first message answered in place (replace_url stream); its typing placeholder (typing_placeholder.js) runs a timer only while /build's first box is on the page.
import "build_shell"
// The agent shell as the conversation grows: the size steps by the thread's height, the first message's entrances, the chat box kept in view; inert where there is no shell.
import "agent_shell"
// A new agent answer types itself in (HTML kept, history and reduced motion instant); inert where there is no chat.
import "agent_reveal"
// The chat thread follows new text for a reader within 20px of its end; one scrolled up is left alone.
import "chat_follow"
import "depth_chart"
import "scroll_tab_stop"
import "logo_gallery"
import "gmail_admin_modal"
import "logo_editor"
import "logo_download"
import "dreams_filter"
// The /build gallery's hover loops: delegated, inert elsewhere.
import "gallery_motion"
// Build My App's launch panel: the three steps, then the CTO's chat (a custom element, inert elsewhere).
import "build_launch"
// The open_modal Turbo Stream action: a signed-out Build My App opens the sign-in modal (only registers the action).
import "modal_stream"
// The chat composer's files (attach, paste, drop; send waits for uploads): delegated, inert elsewhere.
import "chat_attachments"
// The CTO chat usage meter's "Resets in 3d 4h" countdown, ticked each minute: inert where no meter counts down.
import "usage_countdown"
// The app chat status card's live pill countdown, MM:SS ticked each second: inert where no pill counts down.
import "devops_countdown"

// How a board page's chrome reaches the engine board it wraps (board/engine_board).
// Installed here, on every page, so it is there before Alpine initialises a board
// and before Turbo brings one.
import { installEngineBoard } from "board/engine_board"
installEngineBoard()

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
