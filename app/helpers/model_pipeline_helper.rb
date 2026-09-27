# THE MODEL PIPELINE BOARD'S PALETTES.
#
# In a helper rather than inline in the ERB for the reason AppearancesHelper's header
# gives: `config/tailwind.config.js` scans `app/helpers/**/*.rb`, so a class named here
# compiles exactly as one named in a view — while a class ASSEMBLED from a fragment
# ("bg-#{role}/10") compiles in NEITHER place, because the scanner reads text and never
# runs Ruby. Every class below is therefore written out whole, and that is the
# constraint to respect when adding a lane or a tone.
#
# EVERY COLOUR IS A THEME ROLE, never a raw Tailwind palette shade. The board has to
# read in light mode as well as dark, and `bg-emerald-900/50 text-emerald-300` — the
# pattern the content board beside it still uses — is a dark-mode-only spelling that
# turns into unreadable dark-on-dark the moment the theme flips.
module ModelPipelineHelper
  # THE FIVE LANES' COUNT CHIPS. They walk quiet → loud so the row reads left-to-right
  # as progress, and they are built from FOUR roles rather than five because the engine
  # theme HAS four that are safe as text on both themes: neutral, `warning`, `success`
  # and `primary`. There is deliberately no `info` role and no bare `text-danger` /
  # `text-warning` / `text-success` — only the `-ink` partners clear WCAG AA on both
  # surfaces (studio-engine's tailwind config says so in its own comment), so a fifth
  # hue would have had to come from a raw palette shade and would be theme-blind.
  # `source` and `generation` therefore share `primary` at two different weights.
  LANE_COUNT_CLASSES = {
    "designed" => "bg-surface-alt text-muted border border-subtle",
    "defined" => "bg-warning/10 text-warning-ink border border-warning/40",
    "source" => "bg-primary/5 text-primary border border-primary/30",
    "model" => "bg-success/10 text-success-ink border border-success/40",
    "generation" => "bg-primary/20 text-primary border border-primary/50"
  }.freeze

  NEUTRAL_COUNT_CLASSES = "bg-surface-alt text-muted border border-subtle".freeze

  def lane_count_classes(stage) = LANE_COUNT_CLASSES.fetch(stage.to_s, NEUTRAL_COUNT_CLASSES)

  # A LOOK'S OWN CHIP TONES. `warn` is not a failure: a blank physique description is
  # the normal state of every athlete until a separate backfill fills it, and styling
  # it red would make 2,000 correct rows look broken.
  CHIP_TONES = {
    good: "bg-success/10 text-success-ink border-success/40",
    warn: "bg-warning/10 text-warning-ink border-warning/40",
    bad: "bg-danger/10 text-danger-ink border-danger/40",
    info: "bg-primary/10 text-primary border-primary/40",
    neutral: "bg-surface-alt text-muted border-subtle"
  }.freeze

  def pipeline_chip_classes(tone) = CHIP_TONES.fetch(tone&.to_sym, CHIP_TONES[:neutral])

  # THE CARD'S LEFT EDGE, which is the only thing a 1000-foot scan reads before the
  # words. A stale look is the one card the operator must not scroll past, so it is the
  # only one that gets `danger`; a hand-placed card gets `primary` because it is where
  # the board is showing HIS judgement rather than the data's.
  def look_card_edge_classes(reading)
    return "border-l-4 border-l-danger" if reading.stale?
    return "border-l-4 border-l-primary" if reading.hand_placed?

    "border-l-4 border-l-transparent"
  end

  # WHICH GENERATOR MADE THE NEWEST IMAGE — the value off `artifacts.source`, printed
  # as data. Deliberately NOT a case statement over vendor names: the operator's
  # constraint (2026-09-26) is that the generator is registry-driven and swappable, so
  # this board names a STAGE and a card reports whatever produced its artifact. A
  # `case` here would be a second, stale registry of vendors living in a view helper.
  #
  # `titleize` is not used: a source is an identifier ("operator", and whatever the
  # generator registry writes), and titleizing one would print a name the data does not
  # contain.
  def artifact_source_chip(source)
    return nil if source.blank?

    { label: "via #{source}", tone: :neutral }
  end

  # WHAT SITTING IN THIS LANE MEANS, under the column header. The board primitive's
  # `kickoff` slot renders RAW, so this returns an escaped, html_safe fragment; every
  # lane passes one, so all five columns take the same height and no dropzone jogs.
  def lane_blurb_slot(lane)
    return nil if lane.blurb.blank?

    tag.p(lane.blurb, class: "text-3xs text-muted leading-snug")
  end

  # "+N MORE" — the cards a lane is holding back. Appearances::Pipeline caps a lane at
  # LANE_LIMIT for rendering while the count chip keeps the TRUE total, so this chip is
  # what stops the two numbers reading as a contradiction. `header_extra` renders raw,
  # hence tag.* rather than a string.
  def lane_overflow_chip(lane)
    return nil unless lane.overflow.to_i.positive?

    tag.span("+#{lane.overflow} more",
             class: "badge text-3xs #{NEUTRAL_COUNT_CLASSES}",
             title: "This lane holds #{lane.total}; the board renders the top " \
                    "#{Appearances::Pipeline::LANE_LIMIT} by rank.",
             data: { test: "lane-overflow-#{lane.key}" })
  end
end
