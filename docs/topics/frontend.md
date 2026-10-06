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

## Modal host — this app renders the ENGINE's

`app/views/layouts/application.html.erb` renders `studio/modals/host` and passes its
per-callsite modal registrations as a block. That partial resolves to **studio-engine**;
this app ships no copy.

It used to. The app carried a 228-line fork at `app/views/studio/modals/_host.html.erb`,
and **studio-engine is non-isolated** — it does not `prepend_view_path`, so an app view at
the same path silently WINS the lookup. Nothing warns. The fork therefore rendered on every
page while the engine's host grew to 855 lines, and each engine fix had to be re-ported by
hand or it simply never arrived. Adopting deleted the fork and was a **pure upgrade**: the
fork had zero occurrences of `ModalAnimations` (studio-engine 0.65.2: 13), `cardClasses`
(6) and `CARD_WIDTHS` (8), so every modal here was a fixed `max-w-sm` with no animation
registry. It defined no store function the engine lacks — in the browser the adopted store
answers to all fifteen, `captureFocus` and `dialogLabel` among them.

The engine-side counts carry the version they were measured against because **they move**:
they were first written down as 12/6/7 against 0.65.1, and the routine 0.65.2 bump made
that sentence wrong without touching a line of it. Re-derive rather than quote. The claim
that does not move is the fork's zero.

**Prove adoption by RESOLUTION, never by path.** Rendering the engine's path proves nothing
— that is the exact line the fork was serving:

```ruby
ApplicationController.new.lookup_context.find("host", ["studio/modals"], true).identifier
```

Assert that identifier does **not** start with `Rails.root.join("app/views")`. Do **not**
assert it contains `/gems/`: that names how the engine happens to be installed, passes here,
and can never pass in studio-engine's own consumer-CI lane, which bundles the engine as a
path checkout. A consumer assertion in that shape red-sealed a gem publish
(`/tasks/fix-picker-gem-path-assertion`). `test/support/resolved_view.rb` holds the
predicate so it is written once.

Who owns which claim:

- `test/views/modal_host_adoption_test.rb` — the host resolves outside this app, the fork
  file is gone, and an unforked sibling (`_scoped_host`) resolves the same way as a control
  on the lookup itself.
- `test/integration/modal_host_focus_contract_test.rb` — the rendered host carries the focus
  contract. It parses the RENDERED backdrop with `Nokogiri::HTML5` (libxml2 silently drops
  Alpine's `@keydown.*` attributes) and asserts the element's own attributes, because a
  substring assertion against the source is satisfied by the host's own JS comments. Its
  source-reading assertions go through `ResolvedView`, so they describe the file on the page
  and keep biting if anyone re-forks.
- `test/views/layer_scale_adoption_test.rb` — the host paints on `--z-modal` and the scroll
  lock is on `html`, both read from the resolved host.

**Extending the host without forking it again.** The engine ships three seams, so an app
never needs a copy: `window.ModalAnimations` (per-modal enter/exit animation),
`window.StudioModals.CARD_WIDTHS` (per-modal card width by modal id, with
`DEFAULT_CARD_WIDTH`), and an optional `app/views/modals/_host_extras.html.erb` partial
rendered inside the card on every render path — for a modal that belongs to the app rather
than to one call site. The first two are merged OVER the engine defaults, so define them in
an inline script BEFORE the host renders. This app currently uses none of them and takes the
defaults.

`studio/modals/_scoped_host` was never forked here and has always propagated from the engine.

## About page

`/about` (`landing#about`) is the studio's company page: what it does, how a
launch works, who runs it, and the ways to get in touch. Public, static, and
linked from the footer's Company column. Its copy restates the home page and
`/packages`; keep the three in step when one changes.

## Site footer and booking (public pages)

studio-engine renders both (0.83.0; its consumer doc is `docs/SITE_FOOTER.md` in
that repo). This app holds the facts and four call sites, and no footer markup,
style, script or Leaflet of its own.

- **The layout line**: `layouts/application` calls `studio_site_footer`. A
  visitor gets the footer on every page. A signed-in viewer gets it only on the
  controllers in `config.site_footer_controllers` (`landing`, `packages`,
  `build`, `contact_submissions`, `schedule`); every other signed-in page is a
  working surface and carries none.
- **Facts live in one place**: `config.site_footer` in
  `config/initializers/studio.rb` (name, wordmark, logo, tagline, address,
  social profiles, link columns, legal line). The footer prints no phone number,
  by the operator's choice; it is where the SMS registration's reviewers find
  the privacy policy, terms and `/contact`. A link with a `nil` path renders
  disabled (Career); a social entry with a `nil` URL renders its icon unlinked.
- **Booking**: `config.booking_url` is the studio's Google Calendar appointment
  schedule. `studio_booking_frame` puts Google's page inline on `/` (in the
  tinted Get in Touch band) and on `/schedule`. Its `src` waits in `data-src`
  until after the window's `load` and until the frame is near the viewport; from
  640px up it is cropped to the slot picker and opens to the full page when
  focus moves into it.
- **"Schedule a call" links**: write them with
  `studio_booking_link "Label", schedule_index_path`, never by hand. The helper
  adds `data-booking-popup` and `data-studio-booking`; the engine's script
  answers only to links carrying both, so a hand-written link is an ordinary
  link to `/schedule`. A click opens a `<dialog>` holding Google's page (the
  footer renders it; the frame is requested when the dialog first opens). On a
  page that already shows the inline frame (`/`, `/schedule`) the click scrolls
  to that frame instead. The href stays `/schedule`, the fallback. Call sites:
  the footer's Contact column (marked `{ booking: true }` in the facts),
  `landing/about`, and `PackagesHelper#package_cta_link`.
- **The map** is Leaflet 1.9.4 on OpenStreetMap's keyless tiles, served by the
  engine through the asset pipeline (`/assets/studio/leaflet-*.js` and `.css`).
  It is fetched only once the map is within 400px of the viewport, after
  `load`. Dark mode filters the same tiles in CSS; there is no second tile set.
  With scripts blocked, the element is a link to directions. On a touch device
  one finger scrolls the page, not the map.
- **One rule stays app-side**: the end of `app/assets/tailwind/application.css`
  gives the footer's Contact column the wider track it had before the adoption.
  The engine's columns are equal, and `team@mcritchie.studio` is wider than an
  equal track, so it broke across two lines. Do not restyle the footer beyond
  that; change the engine instead.
- **Tests**: `test/integration/site_footer_test.rb` and
  `schedule_page_test.rb` pin this app's facts and where the footer shows;
  `e2e/site_footer.spec.js` and `e2e/booking_frame.spec.js` prove the wiring on
  this app's pages. The scripts themselves are covered in the engine's lane.

## JS Modules (importmap)

- `board/*` — the `/deployments` board effects and the elapsed ticker (`app/javascript/board`, pinned with `pin_all_from`). Pure modules hold the decisions and shapes (`live_fx`, `release_fx`, `ticker`, `colors`) and have node:test unit tests in `test/javascript` (`bin/test-js`, the CI `javascript` job). The `*_dom` modules wire them to the page and install `window.LiveBoardFx`, `window.ReleaseFx` and the ticker once; the partials `tasks/_deployments_live_fx` and `tasks/_release_ticker` import them with a `type="module"` script. A Stimulus controller can import the pure modules unchanged.
- The deploy board's `kanbanBoard` Alpine factory stays inline in `tasks/_deploy_board`: Alpine starts before importmap modules run, so a factory defined in a module would not exist when `x-data` first evaluates.
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
- **Get in Touch section** — the booking frame (`schedule/_booking_frame`): Google Calendar's inline appointment page, also the whole of `/schedule`.
- **Booking frame** — an iframe whose URL waits in `data-src`; an inline script assigns `src` only after the window's `load` event and once the frame is near the viewport, so Google never holds a page's `load` open. It fills its column. From 640px up it is cropped at rest to Google's slot-picker box, and opens to the full frame when focus moves into it, because the booking dialog centres in the frame's full height.
