require "test_helper"

# A `position: sticky` element pins to its NEAREST SCROLL CONTAINER, and any box with
# `overflow` other than visible/clip is one, on BOTH axes: a box scrollable on one axis
# computes the other from `visible` to `auto`. So a header meant to pin to the page
# (sticky + top) inside an `overflow-x-auto` wrapper pins to a scrollport that never
# scrolls vertically: it rides the page up out of view, or, with its `top` offset from
# the wrapper's own edge, sits down over the content it names. Nothing in the markup
# says so. It shipped on /deployments twice (board-lane-header-overlap,
# board-lanes-by-board-width); this lint reads every view so the third one fails here.
#
# THE RULE. Flag a sticky element (a `sticky` class, at any variant, or an inline
# `position: sticky`) whose nearest overflow-auto/scroll/hidden ancestor — static class,
# Alpine `:class` string, or inline style — does not scroll on the axis it pins on.
#
# THE ONE MEASURED EXEMPTION is that axis match, and it is computed, not listed: a
# `sticky left-0` column inside an `overflow-x-auto` table wrapper pins sideways to the
# very scroller it lives in, which is the point of it; a `sticky top-0` cell inside an
# `overflow-auto max-h-…` box scrolls with that box. A sticky with no inset class reads
# as pinning on both axes, so it is never exempt by default.
#
# THE ALLOW-LIST is for what the rule cannot see, and each entry must say WHY and name a
# `requires` token the element must still carry, so the entry stops matching the moment
# the reason stops being true. A stale entry (one that matched nothing) fails too.
#
# WHAT IT CANNOT SEE: nesting across files (a sticky partial rendered inside another
# file's scroller) and markup a Ruby helper emits (`tag.div class: "sticky"`). It reads
# one template at a time, with ERB tags stripped, so both branches of a conditional count.
class StickyScrollAncestorLintTest < ActiveSupport::TestCase
  VIEWS = Rails.root.join("app/views")

  STICKY = /(?:\A|:)sticky\z/
  SCROLLER = /(?:\A|:)overflow(?:-([xy]))?-(?:auto|scroll|hidden)\z/
  STYLE_SCROLLER = /overflow(?:-([xy]))?\s*:\s*(?:auto|scroll|hidden)/
  Y_INSET = /(?:\A|:)-?(?:top|bottom|inset-y)-/
  X_INSET = /(?:\A|:)-?(?:left|right|start|end|inset-x)-/

  ALLOWED = [
    {
      file: "app/views/tasks/_deploy_board.html.erb",
      data_test: "stage-header",
      requires: "group-data-[lane-scroll=true]/lanes:static",
      why: "The lane row carries its sideways scroller only while the lanes are MEASURED to " \
           "overflow (All Stages on a board too narrow for six), and in exactly that state this " \
           "variant takes the header out of sticky. While the lanes fit — the default, decided " \
           "by the row's container query — the row is no scroll container and the header pins " \
           "to the page. e2e/deployments_lane_pin proves both states in a browser."
    }
  ].freeze

  Finding = Struct.new(:file, :element, :scroller, keyword_init: true) do
    def to_s = "#{file}: <#{element.name} #{element['data-test'] || element['class']}> " \
               "pins inside <#{scroller.name} class=\"#{scroller['class']}\" :class=\"#{scroller[':class']}\">"
  end

  # Every class token an element may carry: its static class plus each quoted string in
  # an Alpine class binding (a conditional scroller is the very case that shipped).
  def self.tokens(el)
    bound = %w[:class x-bind:class].filter_map { |name| el[name] }
    el["class"].to_s.split + bound.flat_map { |expr| expr.scan(/'([^']*)'|"([^"]*)"/).flatten.compact.flat_map(&:split) }
  end

  def self.sticky?(el)
    tokens(el).any?(STICKY) || el["style"].to_s.match?(/position\s*:\s*sticky/)
  end

  # The axes an element pins on, from its inset classes or inline style.
  def self.pin_axes(el)
    toks = tokens(el)
    style = el["style"].to_s
    axes = []
    axes << :y if toks.any?(Y_INSET) || style.match?(/(?:\A|;|\s)(?:top|bottom)\s*:/)
    axes << :x if toks.any?(X_INSET) || style.match?(/(?:\A|;|\s)(?:left|right)\s*:/)
    axes.empty? ? %i[x y] : axes
  end

  # The axes a scroller lets the reader scroll, or nil when the element is no scroller.
  # `hidden` is a scroll container the reader cannot scroll: it captures a sticky
  # child on both axes and moves it on neither.
  def self.scroll_axes(el)
    matches = tokens(el).filter_map { |t| t.match(SCROLLER) }
    matches << el["style"].to_s.match(STYLE_SCROLLER)
    matches.compact!
    return nil if matches.empty?

    matches.reject { |m| m[0].include?("hidden") }
           .flat_map { |m| m[1] ? [ m[1].to_sym ] : %i[x y] }.uniq
  end

  def self.scan(source, file)
    html = source.gsub(/<%.*?%>/m, "")
    doc = Nokogiri::HTML5.fragment(html, max_errors: 0)
    stickies = doc.css("*").select { |el| sticky?(el) }
    findings = stickies.filter_map do |el|
      scroller = el.ancestors.find { |a| a.element? && scroll_axes(a) }
      next unless scroller
      next if (pin_axes(el) - scroll_axes(scroller)).empty?

      Finding.new(file: file, element: el, scroller: scroller)
    end
    [ stickies.size, findings ]
  end

  def allowed?(finding)
    ALLOWED.find do |entry|
      entry[:file] == finding.file && entry[:data_test] == finding.element["data-test"] &&
        self.class.tokens(finding.element).include?(entry[:requires])
    end
  end

  test "no sticky element in app/views pins inside a scroller that cannot scroll its axis" do
    files = Dir[VIEWS.join("**/*.erb")].sort
    assert_operator files.size, :>, 100, "the lint must actually read the views"

    sticky_count = 0
    findings = files.flat_map do |path|
      count, found = self.class.scan(File.read(path), Pathname(path).relative_path_from(Rails.root).to_s)
      sticky_count += count
      found
    end
    assert_operator sticky_count, :>, 10, "the views carry sticky elements, so a clean scan means something"

    used = findings.filter_map { |f| allowed?(f) }
    offenders = findings.reject { |f| allowed?(f) }
    assert_empty offenders.map(&:to_s),
                 "a sticky element pins inside an overflow scroller on an axis that scroller never " \
                 "scrolls, so it sticks to nothing (or sits offset over its content). Move the " \
                 "scroller, make it conditional with a stand-down, or allow-list it with a reason."

    stale = ALLOWED - used
    assert_empty stale.map { |e| "#{e[:file]} #{e[:data_test]}" },
                 "an allow-list entry matched nothing: its reason is no longer true, delete it"
  end

  test "every allow-list entry says why and names the token that keeps it true" do
    ALLOWED.each do |entry|
      assert_operator entry[:why].to_s.split.size, :>=, 12, "#{entry[:file]}: an entry must say why"
      assert entry[:requires].present?, "#{entry[:file]}: an entry must name its condition"
    end
  end

  # THE LINT BITES: the shapes it must catch and the ones it must pass, as fragments.
  test "it flags a page-pinned sticky inside a sideways scroller, static or bound, through ERB" do
    flagged = {
      "static x scroller"   => %(<div class="sm:overflow-x-auto"><div class="sticky top-0">h</div></div>),
      "bound x scroller"    => %(<div :class="wide ? 'overflow-x-auto' : ''"><h3 class="sticky top-4">h</h3></div>),
      "inline style top"    => %(<div class="overflow-x-auto"><div class="sticky" style="top: var(--pin)">h</div></div>),
      "hidden clips sticky" => %(<div class="overflow-hidden"><div class="md:sticky top-0">h</div></div>),
      "through ERB"         => %(<div class="overflow-x-auto <%= extra %>"><% if x %><div class="sticky top-0"><%= t %></div><% end %></div>)
    }
    flagged.each do |name, html|
      _count, found = self.class.scan(html, "fixture")
      assert_equal 1, found.size, "#{name} must be flagged"
    end
  end

  test "it passes a sticky that pins on the axis its scroller scrolls" do
    passed = {
      "sticky column in x scroller" => %(<div class="overflow-x-auto"><table><tr><th class="sticky left-0">c</th></tr></table></div>),
      "sticky row in both-axis box" => %(<div class="overflow-auto max-h-[80vh]"><table><tr><th class="sticky top-0">c</th></tr></table></div>),
      "no scroller at all"          => %(<div class="flex"><div class="sticky top-0">h</div></div>),
      "visible is no scroller"      => %(<div class="overflow-x-visible"><div class="sticky top-0">h</div></div>)
    }
    passed.each do |name, html|
      count, found = self.class.scan(html, "fixture")
      assert_equal 1, count, "#{name}: the sticky element must be seen"
      assert_empty found, "#{name} must pass"
    end
  end
end
