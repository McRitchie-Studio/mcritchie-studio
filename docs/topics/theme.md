# Branding & Theme

> **When to read this:** Editing colors, navbar, stage badges, the button system, or anything visual. Pair with `studio-engine/README.md` and `studio-engine/docs/NAVBAR_SETUP.md` for engine-level theme and navbar details.

## Configuration

- **Theme**: Dynamic — engine-generated CSS custom properties from 7 role colors
- **Theme config**: Uses all Studio defaults (violet primary `#8E82FE`). No `theme_*` overrides in `studio.rb`.
- **Admin theme page**: `/admin/theme` — color editor + styleguide (from engine)
- **Primary**: `#8E82FE` Violet — CTAs, buttons, links, hovers, form focus. Views use `text-primary`, `bg-primary`, `bg-primary-700` etc. (dynamic Tailwind palette from CSS vars, not hardcoded violet).
- **Success accent**: `#4BAF50` Green (default) — flash notices, success toasts, active status dots
- **Font**: Montserrat (weights 400-900)
- **Logo**: SVG icon (`app/assets/images/logo-icon.svg`) + "McRitchie **Studio**" (Studio in violet)
- **Navbar Logo generator**: `Logos::NavbarLogo` draws a brand's logo from an icon and a name as pure vector. See [`logos.md`](logos.md).

## Navbar

The header is studio-engine's navbar (`layouts/_navbar`), rendered by `ShellHelper#hub_navbar` from `application.html.erb` with `show_logout_link: true`. The app forks neither it nor `components/_user_nav`; `test/integration/shell_navbar_test.rb` holds that. The engine's `nav-collapse` Stimulus controller (`data-studio-controller="nav-collapse"`) writes `--nav-p` from scrollY once per frame, and the app's `.nav-shell` band in `application.css` sizes the logo 32→20px, the title 24→16px, and the row padding `py-6→py-2` off it with `calc()`, with no timed transition, so nothing positioned off the header lags it. Past the scroll threshold the controller adds `border-subtle` and `shadow-lg`. `data-pin="nav"` publishes `--pin-nav-h`/`--pin-nav-bottom`, which the task board's pinned app strip and lane headers position off in CSS.

What the app adds to the engine's markup is CSS and one rule. The CSS, in the same `.nav-shell` block: the header sits at `--z-nav`, the row is as wide as the page column (80rem), the white logo is inverted on the light theme and takes no circle or shadow, the Log out link keeps one line below 768px, and the title stays one line under 768px (the engine's stacked mobile band is not adopted). The rule is the heading outline: a page has one `h1`. The brand is the `h1` on a page with no heading of its own; where the rendered page carries one (`components/_page_header`, or a hand-written `h1`) `hub_navbar` draws the brand as a `div` with the same classes (`test/integration/heading_outline_test.rb`).

Signed out, the bar shows the links cog, the theme toggle and the sign-in button (`Studio.sign_in_label`). Signed in, it shows the cog, the theme toggle, a Log out link, and the name and avatar as one link to `/profile`. Below 768px the cog and the theme toggle move to a second row under the bar.

The cog toggles the fixed link sidebar (`components/_link_sidebar.html.erb`, the engine's, rendered by the navbar because `Studio.sidebar_sections` is set). The sidebar is full width on mobile, a right rail on desktop, and uses `.studio-link-sidebar-layer` so it sits above page content. Its public and admin trees come from `LinkTreeHelper`, which builds them from the navigation registry (`config/navigation.yml`): `/links` and `/admin/links` render those same sections, while the sidebar combines public links with admin sections only when `admin?` is true. An entry shows when its page's audience is public or the viewer is an admin.

## Token Usage Rules

- **Surfaces**: Use `bg-page`, `bg-surface`, `bg-surface-alt`, `bg-inset` — never hardcode `bg-navy-*`
- **Text**: Use `text-heading`, `text-body`, `text-secondary`, `text-muted` — never hardcode `text-white` for headings or `text-gray-*` for body text
- **Borders**: Use `border-subtle`, `border-strong` — never hardcode `border-navy-*`
- **CSS var naming**: `--color-cta` / `--color-cta-hover` for singular CTA color. Full `--color-primary-{50..900}` palette with RGB variants for Tailwind `primary-*` utilities.
- **Tailwind config**: `config/tailwind.config.js` dynamically loads studio engine's shared config (`const studioColors = require(\`${studioPath}/tailwind/studio.tailwind.config.js\`)`). Safelists `primary-{50..900}` × `bg/text/border` × opacity variants to ensure compilation.

## Stage Badge Palette

Both News and Content badges now resolve to the shared engine palette introduced 2026-05-17 (Tier 1 #2 of `ecosystem-audit-2026-05-17`). The badge component (`_badge.html.erb` in the engine) accepts these stage-* schemes:

| Scheme | Color | First seen on |
|--------|-------|---------------|
| `stage-fresh` | blue | News.new / Content.idea |
| `stage-shaping` | yellow | News.reviewed / Content.hook |
| `stage-structured` | mint | News.processed / Content.script |
| `stage-refined` | emerald | News.refined / Content.assets |
| `stage-cohered` | violet | News.concluded / Content.assembly |
| `stage-shipped` | emerald | Content.posted |
| `stage-closed` | gray | News.archived / Content.reviewed |

Task stage badges use `ApplicationHelper#stage_scheme` over the live
`Task::STAGES` workflow: `designed` renders as `info`, `submitted` as
`warning`, `building`/`reviewed`/`assembled`/`shipped` as `success`,
`blocked` as `danger`, and `archived` as the neutral fallback. Task is a
workflow, not a pipeline, and is not in the News/Content shared palette.

For task workflow count pills and `/stages` badges, use
`ApplicationHelper#task_stage_count_classes`. It intentionally carries both
light and dark classes (`bg-*-100 text-*-900` plus `dark:bg-*-900/50
dark:text-*-200`) and a border, so badges stay readable in the no-JS light
default and in dark mode. Do not paste the old dark-only `bg-*-900/50
text-*-300` pairs into new task workflow surfaces.

## Button System

`.btn` base + `.btn-primary` (uses `--color-cta`), `.btn-secondary` (uses `--color-success`), `.btn-outline` (hover uses `--color-cta`), `.btn-danger` (uses `--color-danger`), `.btn-google` (white, hardcoded `color: #374151` for dark mode compat). Size: `.btn-sm`, `.btn-lg`. The base `.btn` owns the focus-visible outline using `--color-cta`; avoid one-off focus rings on individual button variants unless a control is not using `.btn`.

Icon controls such as the link-sidebar trigger and sidebar close button should use fixed square dimensions, tokenized hover surfaces, and `focus-visible:ring-primary/40`. The link sidebar uses `bg-surface`, `border-subtle`, `bg-surface-alt` hover rows, and the same focus ring so light/dark contrast is consistent.
