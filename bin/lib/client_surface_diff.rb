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
# GRANULARITY — PRESENCE IS PER-FILE, ADDITION IS PER-HUNK, AND THEY DIFFER
#
# CodeDiff's header refuses to decide "this hunk is only comments", because that
# inference is one the gate can be talked out of, and settles on the FILE as the
# honest granularity. That reasoning holds here for PRESENCE and this module
# follows it: a partial that carries an inline <script> is a browser program no
# matter which of its lines you edited, and defect (3) is the proof — an ERB
# COMMENT edit killed the script.
#
# But the same file granularity applied to the REQUIREMENT would block a copy fix
# in a script-bearing partial, which is the over-refusal this gate exists to avoid.
# So the two facts are separated and carry different weights:
#
#   ADDED construct  (a hunk introduces something the browser runs)  -> BLOCKS
#   PRESENT construct (the changed file runs something, diff didn't
#                      add it)                                       -> REPORTS
#
# The blocking half needs no inference about intent: a line that did not exist and
# now does, and the browser executes it, is new browser behavior with no browser
# observation. The reporting half is the honest statement of a risk the machine
# cannot size.
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

  # Roots the browser is SERVED from. This is a location rule and needs the same
  # justification TestOnlyDiff gave its TEST_ROOTS: these are not filing
  # conventions, they are DELIVERY paths. Propshaft/Sprockets publish app/assets
  # and app/javascript; the view layer renders app/views and app/components; public/
  # is served verbatim. A .js file under any of them reaches a browser by
  # construction. A .js file under config/ or bin/ does not, which is why the rule
  # is a root list and not a bare extension test.
  SERVED_ROOTS = %w[
    app/javascript/ app/assets/ app/views/ app/components/ public/
  ].freeze

  # Roots excluded from every production load path — see TestOnlyDiff::TEST_ROOTS.
  # A script here is evidence or a fixture, never a shipped surface.
  TEST_ROOTS = %w[test/ tests/ e2e/ spec/].freeze

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
  # was measured against 406 merged feature units across the hub, studio-engine and
  # turf-monster. It fired on 90 of them and would have REFUSED 65 — with 164 of its
  # 268 detections being a bare Alpine directive. A gate that demands a Playwright
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

  def self.test_path?(path)
    file = normalize(path)
    TEST_ROOTS.any? { |root| file.start_with?(root) }
  end

  # A .js/.ts file the browser is served. Extension alone is not enough — see
  # SERVED_ROOTS.
  def self.script_asset?(path)
    file = normalize(path)
    return false if file.empty? || test_path?(file)
    return false unless SCRIPT_EXTENSIONS.include?(File.extname(file).downcase)

    SERVED_ROOTS.any? { |root| file.start_with?(root) }
  end

  # A template that could embed a browser program. Whether it DOES is a content
  # question, answered by construct_in.
  def self.template?(path)
    file = normalize(path)
    return false if file.empty? || test_path?(file)

    TEMPLATE_EXTENSIONS.include?(File.extname(file).downcase)
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

  # Surfaces this diff ADDS. `added_lines` maps path => [line, ...] for the lines a
  # hunk introduced. These BLOCK: new browser behavior, no browser observation.
  #
  # A served .js/.ts file counts as added-surface whenever the diff touches it at
  # all: the whole file is the program, so there is no "present but not added"
  # reading of a changed line in it.
  def self.added_surfaces(files, added_lines = {})
    Array(files).map { |f| normalize(f) }.reject(&:empty?).uniq.flat_map do |path|
      if script_asset?(path)
        [Surface.new(path: path, reason: "a browser-served script", line: nil,
                     added: true, tier: :program)]
      elsif template?(path)
        # Report the strongest tier this file added, not merely the first hit: a
        # partial that adds both an Alpine attribute and a <script> is a program.
        hits = Array(added_lines[path]).filter_map do |line|
          found = construct_in(line)
          found && Surface.new(path: path, reason: found[0], line: line.to_s.strip[0, 120],
                               added: true, tier: found[1])
        end
        [hits.find(&:program?) || hits.first].compact
      else
        []
      end
    end
  end

  # The blocking subset — added IMPERATIVE browser code.
  def self.added_programs(files, added_lines = {})
    added_surfaces(files, added_lines).select(&:program?)
  end

  # Surfaces the changed files CARRY but this diff did not add. These REPORT.
  # `file_contents` maps path => current content; a path absent from it is simply
  # not classified (deleted, unreadable, or not fetched) rather than guessed at.
  def self.present_surfaces(files, file_contents = {}, added_lines = {})
    added = added_surfaces(files, added_lines).map(&:path).to_set

    Array(files).map { |f| normalize(f) }.reject(&:empty?).uniq.filter_map do |path|
      next if added.include?(path)
      next unless template?(path)

      content = file_contents[path]
      next if content.nil?

      hits = content.to_s.each_line.filter_map { |l| (r = construct_in(l)) && [r[0], r[1], l] }
      hit = hits.find { |h| h[1] == :program } || hits.first
      next unless hit

      Surface.new(path: path, reason: hit[0], line: hit[2].to_s.strip[0, 120],
                  added: false, tier: hit[1])
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
