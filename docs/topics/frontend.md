# Frontend (JS Modules + AI Chat)

> **When to read this:** Adding/modifying JS modules, importmap entries, Alpine components, the chat UI, or the landing page.

## Smooth-load convention (page transitions)

Turbo page swaps materialize behind the current page and present with a view
transition — one render per navigation, no stale-preview flash. Engine-owned
since studio-engine 0.24 (the former app-local copy is deleted):

- `config/initializers/studio.rb` — `config.page_transition_direction` (with `config.smooth_load = true` kept) opts in; the
  engine head then renders `layouts/studio/_smooth_load` (the `view-transition`
  meta Turbo 8 wraps swaps in `document.startViewTransition` +
  `turbo-cache-control: no-preview`). `config.nav_spinner_min_ms = 300` drops
  the nav spinner floor from the engine's 2500ms default.
- Engine `engine.css` ("Smooth-load convention" block) — root fade-out/rise-in
  keyframes plus the `.vt-pinned-header` @utility, the header's named
  transition group (the class stays on the app layout's header). **Exactly one
  `.vt-pinned-header` per page** — a duplicate `view-transition-name` makes the
  browser silently skip the whole transition.
- **The hub's own direction.** `config.page_transition_direction = :left`: every forward page
  change leaves to the left. `config.page_transition_style = :slide` makes it the one 700ms
  slide. Back plays the same slide reversed, leaving to the right: browser Back, an ancestor
  crumb and the phone's parent link (studio-engine `docs/PAGE_TRANSITIONS.md`, "Back"). The direction turns smooth-load on by itself.
- **An inline `view-transition-name` needs `data-vt-morph="<the name>"`**, or the
  element floats still over the moving page. Two pages that share a marked name play
  the engine's fade and the morph, as /build, /build/:token and the app chat do.
  `test/views/page_transition_adoption_test.rb` scans every view for it.
- **The launch panel morphs at its own address.** `build/_launch` stands at the chat's path
  and `build_launch.js` visits that path. It has to stay an advance visit: an advance to the
  same path keeps a shared marked name (engine 0.125.0), and a refresh stays silent.
- **A GET that redirects moves once**: `/login`, `/signup`, `/logout` (engine 0.125.0).
  Turbo renders the response, then visits the final address with that response. The second
  visit draws nothing, and it adds about 300ms before `turbo:load`.
- **A full load moves too** (engine 0.125.0): a `data-turbo="false"` link or form to another
  path plays the same pair, with the chrome held. A reload, a same-path form (the logo kit's
  PATCH forms) and the magic link's consume page load plainly.
- **`turbo:load` comes when the move ends**, about 700ms after the swap, and clicks do
  nothing until then. `turbo:render` and Stimulus `connect` come at the swap. What
  shapes the arriving page has to run at the swap: `agent_shell.js` sizes the shell on
  `turbo:render`, and `agent_reveal.js` remembers the thread there. The others listen on
  `turbo:load` by choice: they start motion or wire a control, and either can wait
  for the end of the move (`scroll_tab_stop.js`, the first-name ask in the layout).
- `app/assets/tailwind/application.css` holds only the agent elements' morph timing.
- `test/integration/smooth_load_layout_test.rb` is the request-level proof that the
  layout wires the metas (the component test alone cannot see the render line dropped);
  `test/views/smooth_load_component_test.rb` proves the engine partial honors both
  settings; `e2e/page_transitions.spec.js` shows what a browser plays.

Slow-load feedback is Turbo's built-in progress bar (default 500ms delay). Browsers
without view-transition support get an instant swap, and under `prefers-reduced-motion`
Turbo skips the transition. So the e2e lane sets `contextOptions: { reducedMotion:
"reduce" }` in `playwright.config.js`. A bare `use.reducedMotion` does nothing. A spec
about motion opts out with `page.emulateMedia({ reducedMotion: "no-preference" })`, or
for a whole file with `test.use({ contextOptions: { reducedMotion: "no-preference" } })`.

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

The hub has no about page of its own. Alex McRitchie's about page lives on
alex.build: `/about` is a 301 to `https://alex.build/about`, and the footer's
Company column links there directly. The home page's old `#about` section went
with it (task hub-drops-about-section, 2026-11-06).

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
  the privacy policy and terms. Its Contact link opens `/chat`, whose quiet
  "Text message sign-up" link reaches the opt-in form at `/contact`. A link with a `nil` path renders
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
  `integrations/index`, and `PackagesHelper#package_cta_link`.
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
- `board/engine_board` is how a board page's own chrome (`tasks/_board`, `news/index`, `contents/index`) reaches the engine board it wraps, for its toast list, its count refresh and its exit animation. `application.js` installs it on every page as `window.HubEngineBoard`: `ready(section)` is a promise for the board's scope and `scope(section)` is the scope now, or null. Where the engine's importmap pins `studio/board`, the scope comes from that module's `scopeFor(element)`, the call the engine's own board controller makes; on an engine without the pin it is read off the element with `Alpine.$data`. `test/javascript/engine_board_test.js` and `e2e/engine_board_reach.spec.js` hold both shapes. Never import `studio/board` statically: an engine without the pin would fail the whole entry module.
- **Every inline `<script>` carries the CSP nonce**: `<script nonce="<%= content_security_policy_nonce %>">`, or `javascript_tag ..., nonce: true`. The hub sends a report-only Content-Security-Policy whose `script-src` admits an inline script only by the request's nonce (`config/initializers/content_security_policy.rb`); `test/integration/content_security_policy_test.rb` scans `/`, `/build` and `/tasks` for one without it. No new inline `on*=` handler either: no nonce covers an attribute. Reading the reports and the enforce criterion: [`deployment.md`](../agents/modules/deployment.md#content-security-policy-report-only).
- Templates are leaving `x-data` and script tags behind: `test/views/inline_script_and_x_data_ratchet_test.rb` pins each template's count of both in `inline_script_and_x_data_pins.yml` beside it. A gain fails, and a loss fails until its pin is lowered.
- The deploy board's `kanbanBoard` Alpine factory stays inline in `tasks/_deploy_board`: Alpine starts before importmap modules run, so a factory defined in a module would not exist when `x-data` first evaluates.
- `dropping_text` — animated text effect on landing page. Tracks timer IDs and cleans up on `turbo:before-cache` to prevent memory leaks.
- `depth_chart` — Alpine `depthChart(reorderUrl)` component for `/teams/:slug/depth-chart`. Wires SortableJS per position (drag-reorder, locked rows filter out), calls reorder/toggle_lock endpoints. Attached to `window.depthChart`.

## AI Chat (Alex Agent)

Public-facing chat interface powered by Claude API. Users can chat with an AI Alex persona.

### Architecture
- **ChatController** — `index` renders chat page, `create` accepts JSON `{ message }` and returns `{ response }`. Conversation history stored in `session[:chat_messages]` (last 10 messages).
- **Chat::AlexResponder** — Service using raw `Net::HTTP` to Claude API. Alex McRitchie persona system prompt. Model: `claude-haiku-4-5-20251001`, max tokens: 1024.
- **The hub's chat with Alex** — the engine's `studio/agent_chat/chat`, drawn by `chat/index` on `/chat`, with one quiet link to the SMS sign-up form at `/contact`.

### Landing Page
- **Hero** — Denver skyline background with Ken Burns pan animation (15s linear), page-colour tint overlay for text contrast (navy in dark mode, pale in light).
- **Get in Touch section** — side by side, 50/50, from `xl` up in a `max-w-7xl` band: the engine's compact chat with Alex (`studio/agent_chat/chat`, `compact: true`, a centred portrait head) on the left under a Chat Now head, and the booking frame (`schedule/_booking_frame`, Google Calendar's inline appointment page, also the whole of `/schedule`) on the right under a Book a Call head with Alex McRitchie's photo (`public/people/alex-mcritchie.webp`; heads: `landing/_get_in_touch_head`), each half about 612px so Google keeps its wide layout and the crop holds. Each column is a subgrid over three rows (head, card, the frame's note), so the cards match: the chat card fills the calendar's height and its thread scrolls inside. Stacked below `xl`, chat first. The page holds no other chat.
- **Booking frame** — an iframe whose URL waits in `data-src`; an inline script assigns `src` only after the window's `load` event and once the frame is near the viewport, so Google never holds a page's `load` open. It fills its column. From 640px up it is cropped at rest to Google's slot-picker box, and opens to the full frame when focus moves into it, because the booking dialog centres in the frame's full height.
