# frozen_string_literal: true

# The words and marks for a brand kit's reach (task logos-table-columns-tidy): each app the kit feeds (BrandKitApp)
# and its Google marketing kit (BrandMarketingKit), as the /logos Apps and kits column draws them (logos/_kit_chip)
# and as an app's page words its line (brand_kit_apps/_status).
module BrandKitStatusHelper
  # Each status, as the mark a chip draws on its right: a check for done, a triangle for Kit changed, a hollow ring
  # for not done or no Google kit. Shape as well as colour, so each reads without its hue, in either theme.
  KIT_STATUS_MARKS = { applied: :done, current: :done, changed: :changed, not_applied: :none, none: :none }.freeze

  KIT_MARK_TONES = { done: "text-success-ink", changed: "text-warning-ink", none: "text-muted" }.freeze

  KIT_MARK_SHAPES = {
    done: '<circle cx="8" cy="8" r="7" fill="currentColor" fill-opacity="0.15" stroke="currentColor" stroke-width="1.5"/>' \
          '<path d="M4.75 8.25 7 10.5l4.25-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
    changed: '<path d="M8 1.75 14.75 13.75H1.25Z" fill="currentColor" fill-opacity="0.15" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>' \
             '<path d="M8 6v3.5" stroke="currentColor" stroke-width="1.75" stroke-linecap="round"/><circle cx="8" cy="11.75" r="1" fill="currentColor"/>',
    none: '<circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5" stroke-dasharray="2.5 2"/>'
  }.freeze

  # The mark for a status (BrandKitApp's :applied, :changed, :not_applied; BrandMarketingKit's :current, :changed; or
  # :none, no Google kit). Hidden from assistive tech: the chip's accessible name carries the status in words.
  def kit_status_mark(status)
    mark = KIT_STATUS_MARKS.fetch(status)
    tag.svg(KIT_MARK_SHAPES.fetch(mark).html_safe, viewBox: "0 0 16 16", class: "h-3.5 w-3.5 shrink-0 #{KIT_MARK_TONES.fetch(mark)}",
                                                    aria: { hidden: true }, data: { test: "kit-chip-mark", mark: })
  end

  # A kit-to-app link's dates: the kit's save and the application.
  def kit_app_dates(link, kit)
    ["Kit #{kit_saved_words(kit)}",
     (link.used_at ? "applied #{kit_day(link.used_at)}#{" (kit of #{kit_day(link.applied_saved_at)})" if link.applied_saved_at}" : "not applied yet")].join("; ")
  end

  # The app page's title for a link's line: its label, then its dates.
  def kit_app_status_title(link, kit, label) = "#{label}: #{kit_app_dates(link, kit)}"

  # A Google kit's dates: the brand kit's save and the publish.
  def marketing_kit_dates(marketing_kit, kit)
    ["Kit #{kit_saved_words(kit)}",
     "published #{marketing_kit.published_at ? kit_day(marketing_kit.published_at) : 'at an unknown time'}" \
     "#{" (kit of #{kit_day(marketing_kit.published_saved_at)})" if marketing_kit.published_saved_at}"].join("; ")
  end

  private

  def kit_day(time) = time&.strftime("%b %-d, %Y")

  def kit_saved_words(kit) = kit&.saved_at ? "saved #{kit_day(kit.saved_at)}" : "never saved"
end
