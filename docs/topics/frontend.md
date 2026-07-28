# Frontend (JS Modules + AI Chat)

> **When to read this:** Adding/modifying JS modules, importmap entries, Alpine components, the chat UI, or the landing page.

## Smooth-load convention (page transitions)

Turbo page swaps materialize behind the current page and present with a view
transition — one render per navigation, no stale-preview flash. Engine-owned
since studio-engine 0.24 (the former app-local copy is deleted):

- `config/initializers/studio.rb` — `config.smooth_load = true` opts in; the
  engine head then renders `layouts/studio/_smooth_load` (the `view-transition`
  meta Turbo 8 wraps swaps in `document.startViewTransition` +
  `turbo-cache-control: no-preview`). `config.nav_spinner_min_ms = 300` drops
  the nav spinner floor from the engine's 2500ms default.
- Engine `engine.css` ("Smooth-load convention" block) — root fade-out/rise-in
  keyframes plus the `.vt-pinned-header` @utility, the header's named
  transition group (the class stays on the app layout's header). **Exactly one
  `.vt-pinned-header` per page** — a duplicate `view-transition-name` makes the
  browser silently skip the whole transition.
- `app/assets/tailwind/application.css` — ONE rule remains app-side: the
  `studio-header` no-cross-fade fix (`animation: none`), which engine 0.24.0's
  CSS lacks. Task `engine-navbar-self-pins` lifts it into the engine.
- `test/integration/smooth_load_layout_test.rb` — request-level proof the layout
  wires the metas (the component test alone can't see the render line dropped);
  `test/views/smooth_load_component_test.rb` proves the engine partial honors
  the `Studio.smooth_load` toggle.

Slow-load feedback is Turbo's built-in progress bar (default 500ms delay).
Browsers without view-transition support get an instant swap; under
`prefers-reduced-motion` Turbo skips the transition itself. e2e runs with
`reducedMotion: "reduce"` (playwright.config.js) so clicks never land
mid-animation.

## JS Modules (importmap)

- `kanban_board` — drag-and-drop task board with optimistic DOM moves, API transitions, toast notifications. Race-condition guard (`_pendingMoves`) prevents concurrent API calls for same task. Attached to `window.kanbanBoard` for Alpine `x-data` access.
- `dropping_text` — animated text effect on landing page. Tracks timer IDs and cleans up on `turbo:before-cache` to prevent memory leaks.
- `alex_chat` — Alpine.js `alexChat()` component for AI chat UI. Handles message sending via POST `/chat`, loading states, auto-scroll, basic markdown formatting. HTML-escape happens before markdown transforms (XSS-safe). Attached to `window.alexChat`.
- `depth_chart` — Alpine `depthChart(reorderUrl)` component for `/teams/:slug/depth-chart`. Wires SortableJS per position (drag-reorder, locked rows filter out), calls reorder/toggle_lock endpoints. Attached to `window.depthChart`.

## AI Chat (Alex Agent)

Public-facing chat interface powered by Claude API. Users can chat with an AI Alex persona.

### Architecture
- **ChatController** — `index` renders chat page, `create` accepts JSON `{ message }` and returns `{ response }`. Conversation history stored in `session[:chat_messages]` (last 10 messages).
- **Chat::AlexResponder** — Service using raw `Net::HTTP` to Claude API. Alex McRitchie persona system prompt. Model: `claude-haiku-4-5-20251001`, max tokens: 1024.
- **Chat widget partial** — `chat/_chat_widget.html.erb` accepts `compact:` local (true for landing page card, false for full `/chat` page). Used in both locations.
- **Alpine.js component** — `alexChat()` in `alex_chat.js` handles message state, fetch to `/chat`, loading indicators, auto-scroll, basic markdown rendering.

### Landing Page
- **Hero** — Denver skyline background with Ken Burns pan animation (15s linear), dark overlay for text contrast.
- **Get in Touch section** — Two cards: "Chat Over Video" (Sprintful inline widget embed via `on.sprintful.com`) and "Chat Right Now" (embedded chat widget).
- **Sprintful widget** — Uses official inline widget JS (`app.sprintful.com/widget/v1.js`), not iframe (public URL blocks iframes via X-Frame-Options).
