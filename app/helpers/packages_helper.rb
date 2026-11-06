# Where a package card's call to action goes. Every action resolves to a live
# link, so a card can never render a dead button:
#
#   build               /build, the App Builder
#   talk                a chat with Alex about this tier: the engine's
#                       talk-to-agent modal (studio/agent_chat/_talk_modal, which
#                       packages/_talk_to_alex renders once per page) opens on a
#                       plain click and Alex answers the opener at once. The href
#                       is /chat, the same chat on its own page: a modified click,
#                       an engine without the modal, or a viewer the chat refuses
#                       lands there.
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
    elsif action == "talk"
      link_to label, chat_index_path, **options, aria: { haspopup: "dialog" },
              data: data.merge(cta_target: "talk", **package_talk_data(package))
    else
      studio_booking_link label, schedule_index_path, **options, data: data.merge(cta_target: "schedule")
    end
  end

  # The talk-to-agent marks (studio-engine docs/AGENT_CHAT.md, "Talk to an agent
  # in a modal"): Alex, the tier as the topic, and the visitor's first message.
  # Written here rather than with the engine's studio_talk_to_agent_link so the
  # page renders the same link on an engine that predates the modal.
  TALK_SOUL = "alex".freeze
  # Alex's line under his name in the talk modal: his seat on the accountability
  # chart (config/accountability_chart.yml), not /build's "AI Builder".
  TALK_ROLE = "Sales & Marketing".freeze

  def package_talk_data(package)
    { studio_talk_to_agent: true, talk_soul: TALK_SOUL, talk_topic: package.name,
      talk_opener: "I'm looking at the #{package.name} plan. Can you tell me about it?" }
  end

  # Whether this page can open the talk-to-agent modal: the engine ships the
  # partial and the app chats with Alex.
  def package_talk_modal?
    lookup_context.exists?("talk_modal", [ "studio/agent_chat" ], true) && Studio.agent_chat_soul_list.include?(TALK_SOUL)
  end

  HOSTNAME = /\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/i

  # A matrix value as the pieces it may break between: a value that lists
  # hostnames ("yourname.com + www.yourname.com") breaks only at its " + ",
  # never inside a hostname. Each piece is [text, hostname?].
  def package_cell_segments(value)
    value.to_s.split(" + ").map { |part| [ part, part.match?(HOSTNAME) ] }
  end

  # A card tagline with every hostname in it kept on one line, so
  # "your-app.mcritchie.app" never breaks at its hyphen.
  def package_tagline(text)
    parts = text.to_s.split(/(\s+)/).map do |word|
      host, tail = word.match(/\A(.+?)([.,;:!?]?)\z/).captures
      host.match?(HOSTNAME) ? safe_join([ tag.span(host, class: "whitespace-nowrap", data: { test: "tagline-host" }), tail ]) : word
    end
    safe_join(parts)
  end

  # A lone hostname that may wrap only at its first label, and only while a dot
  # remains after it ("yourname." / "mcritchie.app"), so a narrow phone column
  # never splits a word and "yourname.com" never wraps. A hostname listed with
  # another ("yourname.com + www.yourname.com") wraps only at the " + ".
  def package_hostname(text)
    first, rest = text.split(".", 2)
    rest&.include?(".") ? safe_join([ "#{first}.", tag.wbr, rest ]) : text
  end

  # A "<product> · <metric>" value as [product, metric]; any other value as
  # [value, nil]. The matrix draws the metric as a smaller muted second line.
  def package_cell_parts(value)
    product, metric = value.to_s.split(" · ", 2)
    [ product, metric.presence ]
  end

  # "✓", the row's value, or "—" — one cell of the full-stack matrix.
  def package_cell_text(value)
    return "—" if value.nil?
    return "✓" if value == true

    value
  end
end
