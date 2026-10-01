# Where a package card's call to action goes. Every action resolves to a live
# link, so a card can never render a dead button:
#
#   build               /build, the App Builder
#   schedule            /schedule, opened as the booking popup (the studio's
#                       Google Calendar appointment page in a dialog; the href is
#                       the no-script fallback)
#   enterprise_booking  the configured enterprise_booking_url in a new tab, or —
#                       while it is blank — the same booking popup as `schedule`
module PackagesHelper
  def package_cta_link(package, **options)
    action = package.cta["action"]
    label = package.cta["label"].presence || "Get started"
    data = { test: "package-cta", cta_action: action }.merge(options.delete(:data) || {})

    if action == "enterprise_booking" && (url = WorkspacePackage.enterprise_booking_url)
      link_to label, url, **options, target: "_blank", rel: "noopener", data: data.merge(cta_target: "enterprise-booking")
    elsif action == "build"
      link_to label, build_path, **options, data: data.merge(cta_target: "build")
    else
      link_to label, schedule_index_path, **options, data: data.merge(cta_target: "schedule", booking_popup: true)
    end
  end

  # "✓", the row's value, or "—" — one cell of the full-stack matrix.
  def package_cell_text(value)
    return "—" if value.nil?
    return "✓" if value == true

    value
  end
end
