# Where a package card's call to action goes. Every action resolves to a live
# link, so a card can never render a dead button:
#
#   build               /build, the App Builder
#   schedule            /schedule, opened as the booking popup (the studio's
#                       Google Calendar appointment page in a dialog; the href is
#                       the no-script fallback). Written with the engine's
#                       `studio_booking_link`, which marks it as a link the
#                       engine's popup script answers to.
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
      studio_booking_link label, schedule_index_path, **options, data: data.merge(cta_target: "schedule")
    end
  end

  HOSTNAME = /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/i

  # A matrix value as the pieces it may break between: a value that lists
  # hostnames ("yourname.com + www.yourname.com") breaks only at its " + ",
  # never inside a hostname. Each piece is [text, hostname?].
  def package_cell_segments(value)
    value.to_s.split(" + ").map { |part| [ part, part.match?(HOSTNAME) ] }
  end

  # A lone hostname that may wrap only at its first label, and only while a dot
  # remains after it ("yourname." / "mcritchie.studio"), so a narrow phone column
  # never splits a word and "yourname.com" never wraps. A hostname listed with
  # another ("yourname.com + www.yourname.com") wraps only at the " + ".
  def package_hostname(text)
    first, rest = text.split(".", 2)
    rest&.include?(".") ? safe_join([ "#{first}.", tag.wbr, rest ]) : text
  end

  # "✓", the row's value, or "—" — one cell of the full-stack matrix.
  def package_cell_text(value)
    return "—" if value.nil?
    return "✓" if value == true

    value
  end
end
