require "test_helper"

# [component] The hub renders the ENGINE's "at" format (studio-engine 0.40) — its
# local fork is retired. Until this landed the same 200-line re-stamper lived in
# BOTH repos, kept byte-identical BY HAND, and the Indiana/Louisville zone-alias
# bug had to be fixed twice. One copy is the whole point.
#
# Four legs, and they are deliberately different KINDS of assertion:
#
#   1. the fork stays deleted, in constant space as well as on disk
#   2. at_time_tag arrives by plain helper inheritance and is OWNED by the gem
#   3. the re-stamper on a real hub page is a well-formed script ELEMENT
#   4. the gem's US zone list still satisfies the membership PROPERTY
#
# WHAT THIS FILE CANNOT DO, STATED PLAINLY. A Rails test observes a String. It
# can never watch the re-stamper run. That is the e2e lane's job
# (e2e/at_time_flag.spec.js waits on data-at-zone, which only the running script
# writes). Leg 3 asserts the STRUCTURE the browser will build from these bytes,
# which is the strongest claim available here — see its own note.
class AtTimeGemAdoptionTest < ActionDispatch::IntegrationTest
  RETIRED = %w[
    app/helpers/at_time_helper.rb
    app/views/shared/_at_time_script.html.erb
  ].freeze

  GEM_PARTIAL = Studio::Engine.root.join("app/views/studio/_at_time_script.html.erb")

  setup do
    Release.delete_all
    @release = Release.open!(branch: "release/at-format-adoption")
    @release.update!(state: "shipped", shipped_at: 2.minutes.ago)
  end

  test "the hub's local at-format fork stays retired" do
    RETIRED.each do |path|
      refute Rails.root.join(path).exist?,
             "#{path} is back — an app fork shadows the gem and re-opens the by-hand drift that " \
             "made the Indiana zone bug a two-repo fix"
    end

    refute Object.const_defined?(:AtTimeHelper),
           "a top-level AtTimeHelper is autoloadable again; the hub copy must not merely be " \
           "unrendered, it must be gone"
  end

  test "at_time_tag reaches the hub through plain helper inheritance, owned by the gem" do
    assert_includes ApplicationController._helpers.instance_methods, :at_time_tag,
                    "the hub reaches at_time_tag through the engine's app/helpers joining the " \
                    "host helper path — no wiring, no `helper Studio::AtTimeHelper`"

    assert_equal Studio::AtTimeHelper,
                 ApplicationController._helpers.instance_method(:at_time_tag).owner,
                 "presence is not adoption: a hub-local redefinition would satisfy the line above " \
                 "while quietly restoring the second copy this task deleted"
  end

  # THE RE-STAMPER MUST BE ABLE TO RUN, WHICH IS NOT THE SAME AS BEING PRESENT.
  #
  # The retired guard was `assert_includes body, "__atTimeFmt"`, and it PASSED over
  # a dead script: a close-tag inside the partial's leading ERB comment ended that
  # comment early, the leaked prose named a script tag inside angle brackets, and
  # the browser opened a phantom element that swallowed the real one. The bytes
  # were all still on the page. Nothing executed.
  #
  # So this parses the page the way a browser does and demands that the element
  # carrying the re-stamper BEGIN with its IIFE. Leaked prose ahead of the real
  # open tag lands INSIDE this element's text, so anything before "(function" means
  # a phantom swallowed the script. Mutation-proved on 2026-08-12 against the
  # installed gem: reintroduce the leaked prose and the retired one-liner still
  # passes while this one fails, naming the text that swallowed it.
  test "the re-stamper is a well-formed script element on a real hub page, not text containing one" do
    get deployments_path
    assert_response :success

    carriers = Nokogiri::HTML(response.body).css("script").select { |s| s.text.include?("__atTimeFmt") }

    assert_equal 1, carriers.size,
                 "expected exactly one script element to carry the re-stamper — zero means the " \
                 "layout stopped rendering studio/at_time_script, two means a fork is back"

    assert carriers.first.text.lstrip.start_with?("(function"),
           "the re-stamper's script element must BEGIN with its IIFE — anything before it is " \
           "leaked page text that has swallowed the script, and nothing will execute. Saw: " \
           "#{carriers.first.text.lstrip[0, 120].inspect}"
  end

  test "the release badge still renders the at-stamp markup contract the script re-stamps through" do
    get deployments_path
    assert_response :success

    stamp = Nokogiri::HTML(response.body).at_css("[data-test='release-state-badge'] time[data-at-stamp]")
    assert stamp, "the Last Release badge must render a live at-stamp, not a hand-written clock"

    refute_empty stamp["data-at-epoch"].to_s, "the epoch is the client's only input"
    assert stamp.at_css("[data-at-text]"), "the text slot the client rewrites"
    assert_match(/ago ·/, stamp["title"].to_s, "the relative phrase this format replaced is demoted, not deleted")

    flag = stamp.at_css("[data-at-flag]")
    assert flag, "the flag slot the client fills"
    assert_equal "", flag.text,
                 "the server must never assert a country — it cannot know where the reader sits"
  end

  # ==== THE ZONE LIST, AND THE LANE THAT CANNOT SEE IT ==============================
  #
  # WHY A RUBY TEST GUARDS A JAVASCRIPT ARRAY. The flag bug was a MEMBERSHIP bug:
  # a browser hands back the CLDR-canonical zone id, and the engines disagree about
  # which that is. Chromium and WebKit report America/Indianapolis and
  # America/Louisville; Firefox reports America/Indiana/Indianapolis and
  # America/Kentucky/Louisville. Both spellings must be members or one engine's
  # readers see a foreign flag inside the US.
  #
  # The e2e lane cannot protect this. playwright.config.js runs ONE project,
  # Chromium, and there is no browser matrix and no nightly backstop anywhere in
  # the ecosystem — so on CI every long-form id canonicalizes to a short one before
  # isUS() ever sees it. Delete US_PREFIXES' Indiana and Kentucky entries and the
  # e2e lane stays GREEN while every Firefox reader in those metros breaks.
  #
  # This test is the lane that does see it, and the choice of lane is the point:
  # the list lives in the GEM now, and studio-engine's consumer-ci.yml runs this
  # hub's `bundle exec rails test` against the engine's own PR head — Ruby only,
  # never the e2e lane. So an engine PR that thins the zone list goes red HERE,
  # in the engine's own CI, before it can ever reach a gem release.
  #
  # It asserts the PROPERTY (a US reader gets no flag), not the spellings: it reads
  # the two data structures out of the shipped partial and evaluates the same rule
  # isUS() evaluates. The mirror is pinned to the original below, so a rewritten
  # isUS() fails here instead of silently drifting away from its copy.
  test "the gem's isUS rule is still the rule this test mirrors" do
    body = partial_source[/function isUS\(zone\) \{(.*?)\n    \}/m, 1]

    assert body, "isUS() is no longer where this test reads it from"
    assert_includes body, "US_ZONES.indexOf(zone) !== -1",
                    "the exact-member half of the rule changed — re-derive us_zone? below before " \
                    "trusting anything it says"
    assert_includes body, "US_PREFIXES.some(",
                    "the prefix half of the rule changed — re-derive us_zone? below"
  end

  test "every zone spelling a browser can report from inside the US carries no flag" do
    # Deliberately NOT America/Fort_Wayne or US/East-Indiana-as-reported: no engine
    # reports those, they canonicalize to America/Indianapolis first. The e2e lane
    # drives them through a real Intl; this one asserts only what isUS() is handed.
    {
      "America/Indianapolis" => "Chromium + WebKit spelling of Indiana",
      "America/Indiana/Indianapolis" => "Firefox spelling of Indiana",
      "America/Louisville" => "Chromium + WebKit spelling of Kentucky",
      "America/Kentucky/Louisville" => "Firefox spelling of Kentucky",
      "Pacific/Midway" => "the territory that was wrong in every engine",
      "America/North_Dakota/Center" => "the remaining long-form US family",
      "US/East-Indiana" => "the legacy US/ floor for an engine that does not canonicalize",
      "America/Chicago" => "an ordinary mainland zone",
      "America/Los_Angeles" => "an ordinary mainland zone",
      "Pacific/Honolulu" => "a state outside the mainland",
      "America/Puerto_Rico" => "a territory"
    }.each do |zone, why|
      assert us_zone?(zone),
             "#{zone} (#{why}) is no longer a US member of the GEM's list, so a reader there is " \
             "shown a foreign flag inside their own country. Chromium-only CI cannot see this."
    end
  end

  test "the US list has not been widened until the flag stops meaning anything" do
    # The opposite failure, and the one a panicked fix reaches for: make everything
    # US and the flag never fires again. The flag carries signal only because it is
    # unusual, so the negative cases are as load-bearing as the positive ones.
    %w[Asia/Tokyo Europe/London America/Argentina/Buenos_Aires Australia/Sydney UTC].each do |zone|
      refute us_zone?(zone), "#{zone} is not in the United States"
    end
  end

  private

  def partial_source
    @partial_source ||= begin
      assert GEM_PARTIAL.exist?,
             "the gem no longer ships studio/_at_time_script — the layout's render is broken and " \
             "every stamp in the hub is frozen in the app's timezone"
      GEM_PARTIAL.read
    end
  end

  # US_ZONES is one JS expression built by concatenating quoted chunks and calling
  # .split(" "). Joining the literals and splitting reproduces it exactly.
  def gem_us_zones
    @gem_us_zones ||= begin
      src = partial_source[/var US_ZONES = \((.*?)\)\.split\(" "\)/m, 1]
      assert src, "could not read US_ZONES out of the gem's partial — the mirror below is blind"
      zones = src.scan(/"([^"]*)"/).flatten.join.split(" ")
      # Non-empty ONLY. A count floor here would quietly become a second content
      # assertion, and it would fire with the wrong message the day someone
      # legitimately restructures the list — the membership tests own that verdict.
      refute_empty zones, "parsed no zones out of the gem's partial; every membership assertion " \
                          "built on this list would be vacuous"
      zones
    end
  end

  def gem_us_prefixes
    @gem_us_prefixes ||= begin
      src = partial_source[/var US_PREFIXES = \[(.*?)\]/m, 1]
      assert src, "could not read US_PREFIXES out of the gem's partial"
      prefixes = src.scan(/"([^"]*)"/).flatten
      refute_empty prefixes, "parsed no prefixes out of the gem's partial; the long-form " \
                             "Indiana/Kentucky families would then be 'missing' for the wrong reason"
      prefixes
    end
  end

  # The Ruby mirror of isUS(), pinned to the original by the test above.
  def us_zone?(zone)
    gem_us_zones.include?(zone) || gem_us_prefixes.any? { |prefix| zone.start_with?(prefix) }
  end
end
