# frozen_string_literal: true

module MarketingKit
  # The Proposal template (task cw-proposal-page-layout; Alex McRitchie 2026-11-27, from Commercial Welding's IPA-ENG
  # proposal): one section per page, the brand's two-tone bar across the top and bottom of every page, details that
  # price the job by category with sub-items, the client logos, and a signature block after the terms.
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

    def initialize(spec)
      @spec = spec
    end

    def name = Layout.template_name(@spec.short, :proposal)

    def payload
      pr = @spec.proposal
      {
        font: @spec.fonts[:family],
        colours: { primary: c(:primary), accent: c(:accent), dark: c(:dark), ink: INK, grey: GREY, line: LINE, white: "#FFFFFF" },
        images: images(pr),
        legal_name: @spec.legal_name,
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
    end

    private

    def c(key) = @spec.colour(key)

    def images(pr)
      { logo_box: @spec.logo_png(:full, :dark), icon: @spec.logo_png(:icon, :light), cover: @spec.slot(:proposal_cover),
        about: @spec.slot(:proposal_about), why: @spec.slot(:proposal_why),
        clients: pr[:clients_logos].presence && @spec.photo_path(pr[:clients_logos]) }
    end

    def cover(pr)
      { credentials: pr[:credentials_line]&.upcase, certifications: pr[:certifications_field],
        number: pr[:number_format] || "#{@spec.short}-YYYY-000" }
    end

    # The detail rows, each [label, lines]: a string is one line, a list is bullets. The Scope / Pricing row (the first
    # whose label names pricing; else a Pricing row after the scope) carries the breakdown and the total.
    def details(pr)
      rows = Array(pr[:details].presence || DEFAULT_DETAILS).map { |label, value| { label: label, lines: Array(value), bullets: value.is_a?(Array) } }
      at = rows.index { |r| r[:label].to_s.match?(/pricing/i) }
      unless at
        at = (rows.index { |r| r[:label].to_s.match?(/scope/i) } || 1) + 1
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
