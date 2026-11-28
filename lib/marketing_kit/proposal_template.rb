# frozen_string_literal: true

module MarketingKit
  # The Proposal template (task cw-proposal-page-layout; Alex McRitchie 2026-11-27, from Commercial Welding's IPA-ENG
  # proposal, then redrawn quieter: "a bit more elegant"): one section per page, each opened by a numbered label and
  # a title; a running header with the logo; details, then an investment page pricing the job by category with
  # sub-items; the client logos; and a signature page after the terms.
  #
  # Drive's HTML import drops page breaks, headers and footers, so this template is a Word file that Drive converts to a
  # Google Doc, drawn by script/marketing_kit/office.py (`proposal`). Ruby decides every word and colour here; the
  # script only lays them out. A value in [brackets] is a field the person filling it in replaces, drawn in the accent
  # colour; a value with no brackets at all is one whole field.
  class ProposalTemplate
    INK = "#1F2933"
    GREY = "#6B7785"
    LINE = "#C9D6E3"

    DEFAULT_DETAILS = [["Project", "Project name and site address"], ["Location", "In shop / In field"],
                       ["Scope / Pricing", "Describe the work in one line: what, how many people, how long"],
                       ["Duration", ["Written acceptance of this proposal is required to place this work on our schedule.", "[X weeks] of work"]],
                       ["Other conditions", ["Pricing is good for [30] days."]],
                       ["Payment terms", ["[Deposit / progress billing / due on receipt]"]]].freeze
    DEFAULT_BREAKDOWN = [{ category: "Materials", items: [] }, { category: "Labor", items: [] }, { category: "Equipment and supplies", items: [] }].freeze

    # The dark tone (Alex McRitchie, 2026-11-27): the same pages on the brand's dark colour, titles in white, the
    # on-dark accent and the dark horizontal logo. A kit builds it
    # beside the light one when its spec sets proposal.dark.
    DARK = { ink: "#DCE3EA", grey: "#8E9DAE", hair: "#24364A" }.freeze

    def initialize(spec, tone: :light)
      raise Error, "unknown proposal tone #{tone.inspect}" unless %i[light dark].include?(tone)

      @spec = spec
      @tone = tone
    end

    def dark? = @tone == :dark

    def name = dark? ? "#{Layout.template_name(@spec.short, :proposal)} (Dark)" : Layout.template_name(@spec.short, :proposal)

    def payload
      pr = @spec.proposal
      base = {
        font: @spec.fonts[:family],
        colours: { primary: c(:primary), accent: c(:accent), dark: c(:dark), ink: INK, grey: GREY, line: LINE, white: "#FFFFFF" },
        images: images(pr),
        legal_name: @spec.legal_name,
        headings: headings(pr),
        focus: photo_focus(pr),
        tagline: @spec.tagline.delete_suffix(".").upcase,
        motto: pr[:motto]&.upcase,
        cover: cover(pr),
        about: { text: pr[:about] || @spec.one_sentence, columns: Array(pr[:about_columns]).first(2) },
        details: details(pr),
        clients: { names: Array(pr[:clients]), note: pr[:clients_note] },
        why: { columns: Array(pr[:why]).first(2), contact: contact },
        terms: pr[:terms_of_service] && { intro: Array(pr.dig(:terms_of_service, :intro)), items: Array(pr.dig(:terms_of_service, :items)) },
        acceptance: { email: @spec.contact[:proposals_email] || @spec.contact[:email], terms: pr[:terms_of_service].present? }
      }
      dark? ? darken(base, pr) : base
    end

    private

    def c(key) = @spec.colour(key)

    def darken(base, pr)
      base.merge(page: c(:dark), hair: DARK[:hair],
                 colours: base[:colours].merge(primary: "#FFFFFF", accent: c(:accent_on_dark), ink: DARK[:ink], grey: DARK[:grey]),
                 images: base[:images].merge(logo: @spec.logo_png(:horizontal, :dark),
                                             clients: (pr[:clients_logos_dark].presence && @spec.photo_path(pr[:clients_logos_dark])) ||
                                                      base.dig(:images, :clients)))
    end

    def images(pr)
      { logo: @spec.logo_png(:horizontal, :light), icon: @spec.logo_png(:icon, :light), cover: @spec.slot(:proposal_cover),
        about: @spec.slot(:proposal_about), why: @spec.slot(:proposal_why),
        clients: pr[:clients_logos].presence && @spec.photo_path(pr[:clients_logos]) }
    end

    # Each section opens with a small label over a title. The about title is the tagline; the rest read as a
    # proposal reads to a client. About and why open on a photo, with one line (proposal.about_line, why_line) saying
    # what the section is for.
    def headings(pr)
      { about: ["About us", @spec.tagline.delete_suffix("."), pr[:about_line]].compact, details: ["Proposal details", "The project"],
        investment: ["Investment", "Pricing"], clients: ["Clients", "Who we work with"],
        why: ["Why choose us", pr[:why_title] || "Why #{@spec.name}", pr[:why_line]].compact,
        terms: ["Terms of service", "Terms and conditions"], acceptance: ["Acceptance", "Agreement to proceed"] }
    end

    # The credentials as badges: a title, who holds it, and the credential body's logo when the spec gives one (logo, and
    # logo_dark for the dark tone: one-tone files in photos/, as the client logos are).
    def badges(pr)
      Array(pr[:credential_badges]).map do |b|
        file = (dark? && b[:logo_dark].presence) || b[:logo].presence
        { title: b[:title].to_s, holder: b[:holder].to_s, logo: file && @spec.photo_path(file) }
      end
    end

    # Where each opening photo's crop sits: 0 keeps its top (or left), 1 its bottom (proposal.photo_focus).
    PHOTOS = %i[cover about why].freeze

    def photo_focus(pr)
      given = pr[:photo_focus] || {}
      PHOTOS.to_h { |k| [k, Float(given.fetch(k, 0.5)).clamp(0.0, 1.0)] }
    end

    def cover(pr)
      { credentials: pr[:credentials_line]&.upcase, certifications: pr[:certifications_field],
        badges: badges(pr),
        number: pr[:number_format] || "#{@spec.short}-YYYY-000" }
    end

    # The detail rows, each [label, lines]: a string is one line, a list is bullets. The Scope / Pricing row (the first
    # whose label names pricing; else a Pricing row after the scope) carries the breakdown and the total.
    def details(pr)
      rows = Array(pr[:details].presence || DEFAULT_DETAILS).map { |label, value| { label: label, lines: Array(value), bullets: value.is_a?(Array) } }
      at = rows.index { |r| r[:label].to_s.match?(/pricing/i) }
      unless at
        at = [(rows.index { |r| r[:label].to_s.match?(/scope/i) } || 1) + 1, rows.size].min # a short list must not pad with nil
        rows.insert(at, { label: "Pricing", lines: [], bullets: false })
      end
      rows[at][:pricing] = { breakdown: breakdown(pr), total_label: pr[:total_label] || "With applicable taxes included:" }
      rows
    end

    def breakdown(pr)
      Array(pr[:pricing_breakdown].presence || DEFAULT_BREAKDOWN).map { |b| { category: b[:category], items: Array(b[:items]) } }
    end

    def contact = [@spec.contact[:phone], @spec.contact[:proposals_email] || @spec.contact[:email]].compact.join(" | ")
  end
end
