# frozen_string_literal: true

# Does this diff ship something THE BROWSER RUNS? The classifier behind
# bin/dor-check's browser-evidence gate.
#
# WHY THIS EXISTS — THREE DEFECTS IN 24 HOURS, EVERY AUTOMATED GATE GREEN
#
# Each shipped or reached review with a full green board, and each was found by a
# human or a reviewer opening a browser:
#
#   1. fix-navbar-offset-jump. Two publishers of --studio-bars-h disagreed, so the
#      header painted at a server-side estimate and MOVED when a ResizeObserver
#      landed the real height. Both existing tests asserted "exactly one pinned
#      header" and both were CORRECT — one header IS rendered. A markup assertion
#      structurally cannot see a post-paint move. Found by eye, on QA.
#   2. local-at-time-format. isUS() matched tzdb LONG-FORM zone ids while Intl
#      reports CLDR-CANONICAL ones, so America/Indiana/Indianapolis resolved to
#      America/Indianapolis and missed every list. US readers saw an "abroad" flag
#      in Chrome and Safari but not Firefox. dor-check PASSED, CI 8/8.
#   3. propagate-at-format-gem. An ERB comment terminated early; the leaked prose
#      contained a literal script tag, which opened a phantom element that
#      SWALLOWED THE REAL SCRIPT. The client half was dead in every browser. All
#      four CI lanes green.
#
# AND THE SHARPEST FACT, WHICH SETS THIS MODULE'S EVIDENCE RULE. The guard test for
# (3) was `assert_includes html, "__atTimeFmt"` — and it PASSED on the broken page,
# because the token survived INSIDE the text the phantom element swallowed. The test
# written to catch "stamps without a working script" WAS an instance of the disease
# it named. That is why browser evidence here may never be satisfied by a string
# appearing in rendered markup: the evidence must observe the browser DOING
# something, and a Rails integration test observes a String.
#
# THE POLARITY, AND WHY IT IS NOT CodeDiff'S
#
# CodeDiff asks "may this diff SKIP the gate?", so an unknown file is behavior
# (denylist). TestOnlyDiff asks "may this diff CLAIM a lighter shape?", so an
# unknown file is not test content (allowlist). Both are requests for LESS, so in
# both the unknown file blocks the exemption.
#
# This module asks the opposite question: "must this diff be held to MORE?" Fail-
# closed here would mean an unrecognized file demands a Playwright spec — which is
# a blanket browser requirement wearing a detector's clothes. It would make the
# cheapest shape the most expensive, and people route around a shape that over-
# refuses; a shape nobody claims teaches nothing. So detection is STRICTLY
# POSITIVE: this module fires only when it can POINT AT the construct the browser
# executes, and it names the file and the line in the refusal. If it cannot point,
# it says nothing.
#
# Under-firing is therefore the deliberate failure direction. A missed spelling
# costs a detection; a guessed one costs an honest builder a false refusal. The
# e2e lane's contract file makes the mirrored argument for its own gate — there,
# enumerating spellings is how a guard gets DEFEATED, because each spelling is a
# way OUT. Here each pattern is a way IN, so the list is safe to grow and safe to
# be incomplete. What it must never do is guess.
#
# GRANULARITY — WHOLE FILE VERSIONS, NOT HUNKS. THIS WAS LEARNED THE HARD WAY.
#
# CodeDiff's header refuses to decide "this hunk is only comments", because that
# inference is one the gate can be talked out of, and settles on the FILE as the
# honest granularity. This module ignored that for its BLOCKING half — it read the
# lines a hunk added — and review sent it back, because the hunk simply does not
# carry enough context to tell a `<script>` TAG from the WORD `<script>` in prose:
#
#   <%# A data-only node … The page's MutationObserver reads these data-* attrs …
#       the node. NO <script> here — Turbo doesn't execute scripts inside broadcast
#       <template>s. … %>
#
# (live at turf-monster/app/views/contests/_goal_feed_item.html.erb:3). The line
# holding the word carries no `<%#` at all; the comment opened two lines earlier.
# No per-line rule and no per-hunk rule can see that, because the disqualifying
# context is OUTSIDE the hunk. Only whole file versions can answer it.
#
# So both halves now read whole files, masked (see mask_comments), and the BLOCKING
# half compares HEAD against BASE:
#
#   ADDED     a script block that did not exist in base, or any touch of a
#             browser-served .js                                        -> BLOCKS
#   REWRITTEN an existing script's body changed                         -> REPORTS
#   PRESENT   the changed file runs something this diff did not add     -> REPORTS
#
# The added/rewritten line is measured, not asserted — blocking rewrites took hub
# firing from 2.8% to 12.1% and the corpus from 9.3% to 20.6% while catching none
# of the three motivating defects. Re-measure with bin/measure-client-surface
# before moving it.
#
# DELIBERATELY NOT DETECTED — each considered and refused:
#   * CSS. Defect (1) was ultimately a PAINT bug, and a pure-CSS `position: sticky`
#     change could reproduce it with no script in the diff. Detecting it means
#     detecting a cross-file custom-property CONTRACT (one file publishes --x,
#     another reads var(--x)), which a path/line classifier cannot see, and the
#     naive version — "flag added `position:` lines" — fires on every layout tweak
#     in the repo. This is the largest known hole and it is named in the gate's
#     own output rather than papered over. (1) is caught here only because its
#     introducing diff ALSO added the ResizeObserver.
#   * <script type="application/ld+json"> and text/x-template. Data and inert
#     markup; the browser parses them and runs nothing.
#   * Turbo frames/streams. Declarative, server-driven, and covered by the request
#     tier that already exists. Including them would fire on most view work in the
#     repo for a behavior whose failures are server-observable.
#   * .js under test roots (test/, tests/, e2e/). That is the EVIDENCE, not the
#     surface. Counting it would make adding a Playwright spec trigger the demand
#     for a Playwright spec.
#   * Node tooling outside the served roots (playwright.config.js, bin/*.js,
#     config/*.js). It runs in node, not in a browser; no browser can observe it.
module ClientSurfaceDiff
  # Files that ARE browser programs by construction.
  SCRIPT_EXTENSIONS = %w[.js .mjs .jsx .ts .tsx].freeze

  # Roots the browser is SERVED from — THE ONE ROOT LIST, and it governs BOTH
  # halves of this classifier (script_asset? and template?). This is a location rule
  # and needs the same justification TestOnlyDiff gave its TEST_ROOTS: these are not
  # filing conventions, they are DELIVERY paths. Propshaft/Sprockets publish
  # app/assets and app/javascript; the view layer renders app/views and
  # app/components; public/ is served verbatim. A file under any of them reaches a
  # browser by construction. One under config/, bin/ or vendor/ does not, which is
  # why the rule is a ROOT-RELATIVE list and not a bare extension test.
  #
  # THIS EXACT TRAP HAS BITTEN THIS GATE'S FILE BEFORE, AND IT BIT THIS MODULE TOO.
  # The release-owned-version gate matched CHANGELOG.md by BASENAME, and CI vendors
  # dependencies into the tree, so `vendor/bundle/**/CHANGELOG.md` matched sixty-odd
  # third-party changelogs and refused unrelated PRs. It passed locally because a dev
  # tree has no vendor/bundle. Its fix was exact root-relative matching, and a later
  # mutation showed the explicit vendor exclusion had become DEAD CODE once the path
  # match was right.
  #
  # This module shipped with script_asset? root-anchored and template? NOT, and that
  # asymmetry alone re-opened the bug: `vendor/bundle/ruby/3.3.0/gems/actionpack-*/
  # lib/action_dispatch/middleware/templates/rescues/*.html.erb` are real ERB
  # templates carrying real <script> tags. `vendor/` is not in .gitignore, so in CI
  # `git ls-files --others` reports the whole bundle as untracked, client_added_lines
  # reads each untracked file as 100% added lines, and the gate blocked three
  # previously-green DorCheckTest cases (PR #801, run 31565777238). Measured: green
  # locally, red in CI — the same signature as the changelog bite, one gate over.
  #
  # SO THERE IS DELIBERATELY NO VENDOR DENYLIST HERE. A denylist is the shape that
  # rots: it needs a new entry for every packaging convention anyone invents
  # (vendor/, node_modules/, .bundle/, tmp/gems/). Anchoring on the roots the browser
  # is actually served from excludes all of them at once, and excludes the next one
  # nobody has thought of. If a path is not somewhere this app SERVES from, it is not
  # this app's browser surface, whatever its extension says.
  # `vendor/javascript/` is a NAMED SERVED ENTRY, not a hole in a denylist. importmap
  # pins vendored ES modules there and Propshaft serves them, so vendor/javascript/
  # chart.js.js reaches a browser exactly as app/javascript/application.js does —
  # while vendor/bundle/ (gem source, never served) stays excluded by the same rule
  # that excludes everything else outside these roots. Two directories under one
  # parent with opposite answers is precisely why the anchor is a ROOT list and not
  # a `vendor/` prefix judgment in either direction.
  SERVED_ROOTS = %w[
    app/javascript/ app/assets/ app/views/ app/components/ public/ vendor/javascript/
  ].freeze

  # THERE IS DELIBERATELY NO TEST_ROOTS EXCLUSION HERE, AND ITS ABSENCE IS THE PROOF
  # THE ROOT ANCHOR IS RIGHT.
  #
  # This module shipped with one (`test/ tests/ e2e/ spec/`, mirroring
  # TestOnlyDiff::TEST_ROOTS) so that a Playwright spec could never be mistaken for a
  # shipped surface — otherwise adding a spec would trigger the demand for a spec.
  # Once template? and script_asset? were both anchored on SERVED_ROOTS, a mutation
  # run proved that exclusion UNKILLABLE: emptying it changed no test, because no
  # test root can prefix-satisfy any served root (the two lists are provably
  # disjoint, asserted below). It had become dead code.
  #
  # That is the same thing that happened to the changelog gate's explicit vendor
  # exclusion once ITS path match was made exact, and it means the same thing here:
  # when the positive rule is precise, the negative rules it needed stop firing. A
  # dead guard is not free — it reads as load-bearing to the next person, and it
  # cannot be verified, so it silently rots into a lie about what protects what.
  #
  # The PROPERTY it guarded is still asserted, at the right granularity — see
  # test/lib/client_surface_diff_test.rb#test_unit_test_roots_are_never_a_surface,
  # which pins the OUTCOME (a spec is never a surface) rather than the spelling of
  # the mechanism. Widen SERVED_ROOTS to reach a test root and that test goes red.
  def self.disjoint_from_served?(prefix)
    SERVED_ROOTS.none? { |root| prefix.start_with?(root) || root.start_with?(prefix) }
  end

  # Template types that can EMBED a browser program.
  TEMPLATE_EXTENSIONS = %w[.erb .html .htm .haml .slim .rhtml].freeze

  # `type` values on a <script> the browser does NOT execute.
  INERT_SCRIPT_TYPES = %w[
    application/ld+json application/json text/template text/x-template
    text/html text/x-handlebars-template
  ].freeze

  # TWO TIERS, SPLIT ON A REAL PROPERTY — MEASURED, NOT GUESSED
  #
  # The first cut of this module treated every browser-executed construct alike and
  # was measured against 407 merged feature units across the hub, studio-engine and
  # turf-monster. Bare Alpine directives are 148 of the 248 detections in that
  # corpus — the single most common thing a UI diff adds. A gate that demands a Playwright
  # spec for adding `x-show` to a dropdown is the blanket browser requirement this
  # design exists to reject, wearing a detector's clothes. The measurement caught it;
  # the split below is the correction.
  #
  # PROGRAMS block. An inline <script> body and a browser-served .js file are
  # ARBITRARY IMPERATIVE CODE. Their failure modes — a throw on line 3, a wrong
  # branch, a phantom element that swallows the rest of the file — produce a page
  # that renders perfectly and does nothing, which is precisely what no server-side
  # assertion can see. All three motivating defects are in this tier, and none is an
  # Alpine attribute.
  #
  # BINDINGS report. `x-show`, `data-controller`, `onclick=` are DECLARATIVE
  # bindings into a framework that is itself covered. Their presence and their
  # arguments are visible to the markup assertions the repo already writes, their
  # failure surface is one attribute wide, and they are the single most common thing
  # a UI diff adds here. Blocking them buys little and costs the shape's credibility.
  #
  # The line is imperative-vs-declarative, not important-vs-unimportant. A binding
  # CAN break in a browser, which is why it is reported rather than ignored.
  PROGRAM_CONSTRUCTS = [
    [/<script\b(?![^>]*\btype\s*=\s*["'](?:#{Regexp.union(INERT_SCRIPT_TYPES).source})["'])/i,
     "an inline <script>"]
  ].freeze

  BINDING_CONSTRUCTS = [
    [/\bdata-controller\s*=/i,                    "a Stimulus controller binding"],
    [/\bdata-action\s*=/i,                        "a Stimulus action binding"],
    [/\bx-(?:data|init|on:|show|model|bind|text|html|if|for|effect|ref|cloak|transition)\b/i,
     "an Alpine directive"],
    [/(?:\s|^)@(?:click|change|submit|input|keydown|keyup|blur|focus|scroll)(?:\.\w+)*\s*=/i,
     "an Alpine event shorthand"],
    [/(?:\s|^)on(?:click|change|submit|input|load|error|keydown|keyup|blur|focus|mouseover)\s*=/i,
     "an inline DOM event handler"]
  ].freeze

  CONSTRUCTS = (PROGRAM_CONSTRUCTS + BINDING_CONSTRUCTS).freeze

  # tier: :program (blocks) or :binding (reports). See the split above.
  Surface = Struct.new(:path, :reason, :line, :added, :tier, keyword_init: true) do
    def added? = !!added
    def program? = tier == :program
  end

  def self.normalize(path)
    path.to_s.strip.delete_prefix("./")
  end

  # Is this path somewhere THIS APP serves the browser from? The single anchor both
  # predicates below share, so they can never disagree about which tree is real —
  # and the one place vendored dependency source, node_modules, tmp/ and every test
  # root are excluded, without naming any of them.
  def self.served?(path)
    file = normalize(path)
    return false if file.empty?

    SERVED_ROOTS.any? { |root| file.start_with?(root) }
  end

  # A .js/.ts file the browser is served. Extension alone is not enough — see
  # SERVED_ROOTS.
  def self.script_asset?(path)
    served?(path) && SCRIPT_EXTENSIONS.include?(File.extname(normalize(path)).downcase)
  end

  # A template that could embed a browser program. Whether it DOES is a content
  # question, answered by construct_in.
  #
  # ROOT-ANCHORED, exactly like script_asset?. It was not, and that asymmetry is the
  # whole of the vendor bite documented on SERVED_ROOTS: a vendored gem's
  # rescues/*.html.erb is a real ERB template with a real <script> in it, and only
  # the root anchor distinguishes it from one of ours.
  def self.template?(path)
    served?(path) && TEMPLATE_EXTENSIONS.include?(File.extname(normalize(path)).downcase)
  end

  # The first executable construct on `line` as [reason, tier], or nil. The unit of
  # positive detection — everything else in this module is plumbing around it.
  # Programs are tested first so a line carrying both reports as the program.
  def self.construct_in(line)
    text = line.to_s
    PROGRAM_CONSTRUCTS.each { |pattern, reason| return [reason, :program] if text.match?(pattern) }
    BINDING_CONSTRUCTS.each { |pattern, reason| return [reason, :binding] if text.match?(pattern) }
    nil
  end

  # ---- A TAG, NOT THE WORD -----------------------------------------------------
  #
  # THE DEFECT THIS EXISTS FOR. The first cut matched the TEXT `<script` anywhere on
  # an added line, so this — live at turf-monster/app/views/contests/
  # _goal_feed_item.html.erb:3 — exited 1 with "this diff ADDS browser code":
  #
  #   <%# … the node. NO <script> here — Turbo doesn't execute scripts inside
  #       broadcast <template>s. … %>
  #
  # Editing a comment that says there is NO script would have demanded a Playwright
  # spec. Prose comment blocks are this ecosystem's highest-churn edit shape, so it
  # would have fired early and often and trained people straight onto
  # [browser-bypass] — the credibility loss the whole design exists to avoid. It
  # also contradicts this module's own polarity: strictly-positive detection means
  # firing only on what it can HONESTLY judge, and it could not judge this.
  #
  # AND THE MASK MUST NOT BE NAIVE, BECAUSE DEFECT 3 IS THE OPPOSITE MISTAKE. That
  # bug was an ERB comment that TERMINATED EARLY; the leaked prose contained a
  # literal script tag which opened a phantom element that swallowed the real
  # script. So "it looked like a comment" is not proof it was one — a mask that
  # trusts the OPENER would hide the exact defect this gate was built for.
  #
  # The resolution is to mask the way ERB actually parses: NON-GREEDY, closing at
  # the FIRST `%>`. What survives the mask is what the browser really receives, so
  # an early-terminating comment leaks its `<script>` into the scanned text and
  # still fires — while an ordinary well-formed comment does not. The mask is not a
  # heuristic about intent; it is a cheap model of the renderer.
  #
  # Newlines are preserved so masking cannot move line numbers or merge lines.
  def self.mask_comments(text)
    text.to_s
        .gsub(/<%#.*?%>/m) { |m| m.gsub(/[^\n]/, " ") }
        .gsub(/<!--.*?-->/m) { |m| m.gsub(/[^\n]/, " ") }
  end

  # Every construct-bearing line of `content`, AFTER masking, as
  # [normalized_text, reason, tier, raw_line]. The identity used to diff two
  # versions of a file is the normalized line text. Used for the BINDING tier.
  def self.construct_lines(content)
    mask_comments(content).each_line.filter_map do |line|
      found = construct_in(line)
      found && [line.strip.gsub(/\s+/, " "), found[0], found[1], line]
    end
  end

  # An executable <script> and its BODY, from opening tag to `</script>` (or to
  # end-of-file when unclosed — an unclosed script still runs everything after it).
  SCRIPT_BLOCK = %r{<script\b([^>]*)>(.*?)(?:</script>|\z)}mi

  # The whole PROGRAM tier's identity: each executable script block, masked and
  # whitespace-normalized.
  #
  # WHY BLOCKS AND NOT LINES. A line-set diff sees a new `<script>` OPENING TAG but
  # not a rewritten BODY — `var a = 1;` becoming `var a = compute(window.tz);` adds
  # no construct line, so the gate stayed silent on a total rewrite of a browser
  # program. That was a live under-fire in the first version and this test suite
  # caught it. Rewriting a script is exactly as unobservable to a String assertion
  # as adding one, so the block's CONTENT is the thing to compare.
  def self.script_blocks(content)
    mask_comments(content).scan(SCRIPT_BLOCK).filter_map do |attrs, body|
      next if INERT_SCRIPT_TYPES.any? { |t| attrs.to_s.match?(/type\s*=\s*["']#{Regexp.escape(t)}["']/i) }

      "<script#{attrs}>#{body}".gsub(/\s+/, " ").strip
    end
  end

  # Surfaces this diff ADDS — the BLOCKING half. Compares the file's HEAD content
  # against its BASE content and reports only constructs that are NEW.
  #
  # WHY VERSIONS RATHER THAN HUNK LINES. The over-fire above is multi-line: the
  # offending line carries no `<%#` at all, because it is the THIRD line of a
  # comment that opened two lines earlier. A per-line rule cannot see that, and a
  # per-hunk rule cannot either — the context that makes the line prose is outside
  # the hunk. Only the whole file can answer it, so both versions are masked and
  # compared.
  #
  # This also stopped an under-fire nobody had named: a diff that REWRITES the body
  # of an existing inline script adds no `<script` line, so a "did a hunk add the
  # opening tag" rule saw nothing. Under version comparison the changed body lines
  # are new, and it blocks — which is right, since rewriting a script is exactly as
  # unobservable as adding one.
  #
  # `head_contents` / `base_contents` map path => content. A file absent from
  # base_contents is treated as newly added (base = ""). A TEMPLATE absent from
  # head_contents is NOT classified — we cannot mask what we cannot read, and
  # guessing is what the polarity forbids.
  def self.added_surfaces(files, head_contents = {}, base_contents = {})
    Array(files).map { |f| normalize(f) }.reject(&:empty?).uniq.flat_map do |path|
      if script_asset?(path)
        # The whole file is the program; any touch is a change to browser code.
        [Surface.new(path: path, reason: "a browser-served script", line: nil,
                     added: true, tier: :program)]
      elsif template?(path)
        head = head_contents[path]
        next [] if head.nil?

        base = base_contents[path].to_s

        # PROGRAM tier — a script block that did not exist before.
        #
        # ADDED vs REWRITTEN, AND WHY THE LINE IS HERE. An earlier cut blocked on any
        # block whose CONTENT differed from base, which also caught rewriting an
        # existing script's body. That is defensible in principle — a rewritten
        # script is exactly as unobservable as a new one — and it was MEASURED to
        # cost far too much: hub blocking went 2.8% -> 12.1%, turf 17.5% -> 30.0%,
        # the whole corpus 9.3% -> 20.6% of 407 merged units, because roughly one
        # hub PR in eight legitimately edits an inline board/live-FX script.
        #
        # All THREE motivating defects are caught without it — each introduced a
        # NEW script — so the extra 11 points bought no motivating case and doubled
        # the refusal rate. This module's whole credibility rests on being targeted,
        # so the rewrite goes to the REPORT tier instead. That is not a fudge to hit
        # a number: it is the SAME add-vs-carry line the program/binding split
        # already draws, applied one level down. A new block is something the diff
        # ADDED; a changed body is something it CARRIED and touched.
        #
        # Counting is deliberately by block COUNT, not by content identity: delete
        # one script and add another in the same diff and the count holds, so it
        # reports rather than blocks. That is the chosen under-fire direction.
        if script_blocks(head).size > script_blocks(base).size
          fresh = script_blocks(head) - script_blocks(base)
          next [Surface.new(path: path, reason: "an inline <script>",
                            line: (fresh.first || script_blocks(head).first).to_s[0, 120],
                            added: true, tier: :program)]
        end

        # BINDING tier — line identity is enough; a binding IS its line.
        seen_lines = construct_lines(base).reject { |_, _, tier, _| tier == :program }
                                          .map(&:first).tally
        fresh = construct_lines(head).reject do |key, _, tier, _|
          tier == :program || (seen_lines[key].to_i.positive? && seen_lines[key] -= 1)
        end
        next [] if fresh.empty?

        [Surface.new(path: path, reason: fresh.first[1], line: fresh.first[3].to_s.strip[0, 120],
                     added: true, tier: fresh.first[2])]
      else
        []
      end
    end
  end

  # The blocking subset — added IMPERATIVE browser code.
  def self.added_programs(files, head_contents = {}, base_contents = {})
    added_surfaces(files, head_contents, base_contents).select(&:program?)
  end

  # Surfaces the changed files CARRY but this diff did not add. These REPORT.
  # A path absent from `head_contents` is simply not classified (deleted,
  # unreadable, or not fetched) rather than guessed at.
  def self.present_surfaces(files, head_contents = {}, base_contents = {})
    added = added_surfaces(files, head_contents, base_contents).map(&:path).to_set

    Array(files).map { |f| normalize(f) }.reject(&:empty?).uniq.filter_map do |path|
      next if added.include?(path)
      next unless template?(path)

      content = head_contents[path]
      next if content.nil?

      block = script_blocks(content).first
      next Surface.new(path: path, reason: "an inline <script>", line: block.to_s[0, 120],
                       added: false, tier: :program) if block

      hit = construct_lines(content).reject { |_, _, tier, _| tier == :program }.first
      next unless hit

      Surface.new(path: path, reason: hit[1], line: hit[3].to_s.strip[0, 120],
                  added: false, tier: hit[2])
    end
  end

  # ---- The evidence side -------------------------------------------------------
  #
  # WHAT COUNTS AS BROWSER-OBSERVED EVIDENCE, and why it is exactly this.
  #
  # A changed Playwright spec under e2e/ that is IN THE LANE'S EXECUTED SET.
  #
  # The second clause is the whole strength of the definition, and it is borrowed
  # rather than invented. config/e2e_lane.yml already runs a RUNTIME executed-set
  # gate: bin/e2e-executed-set-check reads Playwright's OWN report after the lane
  # runs and asserts `executed == total_specs - quarantined`. That gate exists
  # because static counting cannot answer "how many specs RAN", and every escape
  # hatch — testInfo.skip(), a widened --grep-invert, --only-changed, a file never
  # collected — lives in the gap between the two questions.
  #
  # So this module deliberately does NOT re-answer that question. It proves the
  # cheap half — a browser spec changed alongside the client surface, and its title
  # does not carry the quarantine tag — and COMPOSES with the runtime gate, which
  # proves the expensive half: that the set actually executed in a real browser.
  # Re-implementing a source-side "did it run" check would be the static guard the
  # lane's own contract file explains is worthless.
  #
  # WHAT IS REFUSED AS EVIDENCE, in terms:
  #   * A Rails integration or view test. It renders to a String. That is defect
  #     (3)'s exact failure — `assert_includes html, "__atTimeFmt"` green over a
  #     script that never ran — and no amount of it observes a browser.
  #   * A quarantined spec. It is excluded from the executed set by construction,
  #     so requiring it would accept evidence the lane is contracted NOT to run.
  #   * A prose [control]-style claim. Declarations standing in for evidence is the
  #     disease the whole dor-check header is about.
  SPEC_PATTERN = /\.spec\.(?:js|mjs|ts)\z/i

  def self.browser_spec?(path)
    file = normalize(path)
    file.start_with?("e2e/") && file.match?(SPEC_PATTERN)
  end

  # Changed specs that are NOT wholly quarantined. `spec_contents` maps path =>
  # content; a spec we cannot read is credited (it changed, and the runtime gate
  # will grade it) rather than refused on a read failure.
  def self.evidence_specs(files, spec_contents = {}, quarantine_tag = "@quarantine")
    Array(files).map { |f| normalize(f) }.reject(&:empty?).uniq.select do |path|
      next false unless browser_spec?(path)

      content = spec_contents[path]
      next true if content.nil?

      titles = content.to_s.scan(/\b(?:test|it)\s*\(\s*(["'`])((?:\\.|(?!\1).)*)\1/m).map { |m| m[1] }
      titles.empty? || titles.any? { |t| !t.include?(quarantine_tag) }
    end
  end

  # Does this repo HAVE a browser lane at all? The gate must not demand evidence a
  # repo cannot produce — studio-engine has no e2e/ directory and its CI installs
  # node but runs no browser, so blocking there would be a refusal with no remedy,
  # which is the definition of the over-refusal this design rejects. Where there is
  # no lane the finding REPORTS instead, naming the missing lane as the reason.
  # SHOULD AN ENGINE-SIDE CLIENT DIFF BE GATED ON THE CONSUMER'S LANE? NO — JUDGED,
  # NOT DEFERRED.
  #
  # The engine cannot run a browser, and the hub can, so the tempting move is to
  # reach across the seam: block studio-engine PR N until the hub PR that adopts the
  # gem carries a spec. Three facts make that the wrong gate.
  #
  #   1. IT INVERTS THE DEPENDENCY. The adoption PR does not exist when the engine
  #      PR is submitted — the engine merges, releases a gem version, and a
  #      DIFFERENT task in a DIFFERENT repo bumps Gemfile.lock days later, often by
  #      a different agent. A gate whose evidence is required before its subject can
  #      exist is a gate that blocks forever or is waved through, and waved-through
  #      is what it would be.
  #   2. THE CONSUMER'S SPEC WOULD NOT COVER THE ENGINE'S CODE ANYWAY, except where
  #      the consumer happens to render that partial. The hub's lane observes the
  #      hub's pages; an engine primitive no consumer page exercises stays unseen,
  #      and the gate would report GREEN over it — worse than reporting a hole,
  #      because it would look answered.
  #   3. IT IS MOOT IF THE ENGINE GETS ITS OWN LANE. test/dummy already exists, so a
  #      Playwright lane can boot the dummy host and drive engine views directly —
  #      no seam to cross. That is /tasks/stand-up-engine-browser-lane, and when it
  #      lands, lane_present? flips to true for the engine and the REPORT branch
  #      below becomes a BLOCK with no change to this file.
  #
  # So the cross-repo gate is not filed as "later" — it is refused, and the work it
  # was standing in for is the engine's own lane.
  def self.lane_present?(root = ".")
    File.directory?(File.join(root.to_s, "e2e")) ||
      File.exist?(File.join(root.to_s, "config", "e2e_lane.yml"))
  end
end
