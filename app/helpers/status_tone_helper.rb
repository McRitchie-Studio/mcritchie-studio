# The one place a hub view gets a status colour: a stage, a run result, a
# review verdict, an alert. It maps a status word (or a role) onto the engine's
# five status roles and returns WHOLE, LITERAL Tailwind class strings built
# from engine tokens, so they read correctly in light and dark without a
# `dark:` variant (the theme resolver writes both themes into each token).
#
#   status_tone(:blocked)          # => chip classes for the danger role
#   status_tone("passed", :text)   # => "text-success-ink"
#   status_tone(:warning, :panel)  # => an alert box: tinted fill and border
#
# Every class string below is written out in full on purpose. Tailwind finds
# utilities by scanning source text, so a class assembled at runtime
# ("text-#{role}-ink") is never compiled and silently renders unstyled.
#
# The roles and their tokens (studio-engine tailwind/studio.tailwind.config.js):
#   success / warning / danger  fill `bg-<role>`, ink `text-<role>-ink`
#   primary                     the theme's primary scale; its chip text is
#                               `text-heading`, because the primary colour is
#                               not contrast-derived and fails AA as chip text
#   muted                       the surface and text ladders
# There is deliberately no bare `text-success` / `text-warning` /
# `text-danger`: role colours fail contrast as text, so text uses the ink.
module StatusToneHelper
  STATUS_TONE_ROLES = %i[success warning danger primary muted].freeze

  STATUS_TONE_PARTS = {
    success: {
      chip: "bg-success/10 text-success-ink border border-success/40",
      text: "text-success-ink",
      panel: "bg-success/10 border border-success/40",
      fill: "bg-success",
      border: "border-success/40"
    },
    warning: {
      chip: "bg-warning/10 text-warning-ink border border-warning/40",
      text: "text-warning-ink",
      panel: "bg-warning/10 border border-warning/40",
      fill: "bg-warning",
      border: "border-warning/40"
    },
    danger: {
      chip: "bg-danger/10 text-danger-ink border border-danger/40",
      text: "text-danger-ink",
      panel: "bg-danger/10 border border-danger/40",
      fill: "bg-danger",
      border: "border-danger/40"
    },
    primary: {
      chip: "bg-primary/10 text-heading border border-primary/40",
      text: "text-primary",
      panel: "bg-primary/10 border border-primary/40",
      fill: "bg-primary",
      border: "border-primary/40"
    },
    muted: {
      chip: "bg-surface-alt text-muted border border-subtle",
      text: "text-muted",
      panel: "bg-inset border border-subtle",
      fill: "bg-surface-alt",
      border: "border-subtle"
    }
  }.freeze

  # Status words the hub shows, by role. A role name maps to itself. Anything
  # unlisted is muted: an unknown status reads as quiet, never as an alarm.
  STATUS_TONE_WORDS = {
    success: %w[success good ok passed pass green shipped merged reviewed approved
                done complete completed accepted live healthy handoff],
    warning: %w[warning warn pending waiting submitted queued stale held
                qa_feedback attention partial],
    danger: %w[danger bad error failed failure fail red blocked rejected expired],
    primary: %w[primary info designed building assembling assembled running
                in_progress clarification],
    muted: %w[muted neutral archived abandoned skipped unknown none draft]
  }.flat_map { |role, words| words.map { |word| [word, role] } }.to_h.freeze

  # The role a status word maps to: one of STATUS_TONE_ROLES.
  def status_tone_role(status)
    key = status.to_s.strip.downcase.tr(" -", "__")
    STATUS_TONE_WORDS.fetch(key, :muted)
  end

  # The class string for one part of a status: :chip (default), :text,
  # :panel, :fill or :border. An unknown part raises, so a typo fails loudly
  # in a test rather than rendering an unstyled element.
  def status_tone(status, part = :chip)
    STATUS_TONE_PARTS.fetch(status_tone_role(status)).fetch(part.to_sym)
  end
end
