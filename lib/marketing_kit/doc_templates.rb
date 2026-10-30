# frozen_string_literal: true

module MarketingKit
  # The two Google Doc templates every kit carries: General (a newsletter-style
  # branded page) and Proposal (cover, about, details, pricing, clients, why us,
  # acceptance, and the brand's own terms when the spec has them). Both are
  # HTML for Drive's Doc import, so styles are inline and images are data URIs.
  # Orange [fields] are what the person filling it in replaces.
  class DocTemplates
    include Html

    INK = "#1F2933"
    GREY = "#6B7785"
    LINE = "#C9D6E3"

    DEFAULT_DETAILS = [["Project", "Project name and site address"], ["Scope of work", "Describe the work: what we will deliver, and how"],
                       ["Included", "What the price includes"], ["Not included", "What the client provides or is priced separately"],
                       ["Assumptions", "Access, working hours, site conditions, permits"]].freeze
    DEFAULT_SCHEDULE = [{ phase: "Before we start", steps: ["Proposal accepted", "Kick-off and site visit"] },
                        { phase: "The work", steps: ["Main work", "Progress check-ins"] },
                        { phase: "Finish", steps: ["Final check", "Handover"] }].freeze
    DEFAULT_PRICING = [["Materials", ""], ["Labour", ""], ["Equipment and supplies", ""], ["Project management", ""]].freeze
    DEFAULT_TERMS = [["Validity", "Pricing is good for [30] days."], ["Payment terms", "[Deposit / progress billing / due on receipt]"],
                     ["Exclusions", "[Permits, bonds, after-hours work, etc.]"]].freeze

    def initialize(spec)
      @spec = spec
    end

    def general_name = "#{@spec.short} Template — General"
    def proposal_name = "#{@spec.short} Template — Proposal"

    def general
      g = @spec.general_template
      dots = "<p style='#{font};text-align:center;color:#9AA5B1;font-size:10pt;letter-spacing:3px;margin:6pt 0'>#{'•' * 60}</p>"
      byline = p("by <span style='color:#{c(:accent)};font-weight:700'>Your Name</span> on [Month D, YYYY]", "color:#{GREY};font-size:10pt;margin:2pt 0 6pt 0")
      para = ->(t) { p(t, "color:#{INK};font-size:11pt;line-height:1.4") }
      heading = ->(t) { p(t, "font-weight:700;color:#{c(:title)};font-size:18pt;margin:14pt 0 2pt 0") }
      doc(<<~HTML)
        <p style='text-align:center'><img src='#{data_uri(@spec.logo_png(:full, :light))}' width='300'></p>
        #{dots}
        #{p('Document Title', "font-weight:700;color:#{c(:title)};font-size:30pt;margin:6pt 0 0 0", 'center')}
        #{p('A one-line subtitle that says what this is about.', "color:#{c(:accent)};font-size:12pt;font-weight:500;margin:2pt 0 12pt 0", 'center')}
        <p style='text-align:center'><img src='#{data_uri(@spec.slot(:template_hero))}' width='624'></p>
        #{byline}
        #{para.call('Start here. Lead with the outcome in a sentence or two: what happened, what it means for the reader, and what comes next.')}
        #{para.call("Add detail in short paragraphs. Swap the photo above for one from #{Layout::PHOTOS}: right-click it, then Replace image, then Drive.")}
        #{dots}
        #{p('SECTION LABEL', "color:#{GREY};font-size:10pt;letter-spacing:2px;margin:12pt 0 0 0", 'center')}
        #{p('SECTION TITLE', "color:#{c(:title)};font-size:12pt;font-weight:700;letter-spacing:2px;margin:0 0 12pt 0", 'center')}
        <p style='text-align:center'><img src='#{data_uri(@spec.slot(:template_band))}' width='624'></p>
        #{heading.call('A heading for this item')}#{byline}
        #{para.call('A short paragraph about this item: a finished job, a new service, a milestone or a team member.')}
        #{heading.call('A second heading')}#{byline}
        #{para.call('Another short paragraph. Copy a heading, byline and paragraph together to add more items.')}
        #{button(g[:cta_label] || 'GET IN TOUCH', g[:cta_url] || @spec.contact[:website_url])}
        #{dots}
        <p style='text-align:center;margin-top:12pt'><img src='#{data_uri(@spec.logo_png(:icon, :light))}' width='56'></p>
        #{footer}
      HTML
    end

    def proposal
      pr = @spec.proposal
      doc([proposal_cover(pr), about(pr), details(pr), pricing(pr), clients(pr), why(pr), acceptance(pr), terms_of_service(pr)].compact.join)
    end

    private

    def c(key) = @spec.colour(key)
    def font = "font-family:#{@spec.fonts[:family]},#{@spec.fonts[:fallback]},sans-serif"
    def doc(body) = "<html><head><meta charset='utf-8'></head><body style='#{font}'>#{body}</body></html>"

    def p(text, style = "", align = "left")
      "<p style='#{font};text-align:#{align};color:#{INK};font-size:10.5pt;line-height:1.35;margin:0 0 6pt 0;#{style}'>#{text}</p>"
    end

    def field(t) = "<span style='color:#{c(:accent)};font-weight:700'>[#{h(t)}]</span>"
    def gap = "<p style='#{font};font-size:10pt;margin:0 0 18pt 0'>&nbsp;</p>"
    def motto(pr) = pr[:motto] ? p(h(pr[:motto].upcase), "color:#A0B3C4;font-weight:700;letter-spacing:3px;font-size:9.5pt;margin-top:14pt", "center") : ""
    def photo(slot) = "<p style='text-align:center;margin:0 0 12pt 0'><img src='#{data_uri(@spec.slot(slot))}' width='624'></p>"

    def button(label, url)
      "<table style='border-collapse:collapse;margin:16pt 0;width:250pt' width='250'><tr><td style='background-color:#{c(:accent)};padding:9pt 16pt;border:0'>" \
        "<p style='#{font};margin:0'><a href='#{h(url)}' style='color:#FFFFFF;font-weight:700;letter-spacing:1px;font-size:11pt;text-decoration:none'>#{h(label)}</a></p></td></tr></table>"
    end

    def footer
      lines = Array(@spec.contact[:lines])
      p(h(lines.first), "color:#{c(:primary)};font-weight:700;font-size:10.5pt;margin:6pt 0 0 0", "center") +
        lines.drop(1).map { |l| p(h(l), "color:#{INK};font-size:10pt;margin:0", "center") }.join +
        p(h(@spec.tagline.delete_suffix(".").upcase), "color:#{c(:accent)};font-weight:700;font-size:9pt;letter-spacing:2px;margin:8pt 0 0 0", "center")
    end

    def band(title)
      "<table style='border-collapse:collapse;width:100%;margin:0 0 14pt 0' width='100%'><tr>" \
        "<td style='background-color:#{c(:primary)};padding:12pt 18pt;border:0;width:80%'><p style='#{font};margin:0;color:#FFFFFF;font-weight:700;font-size:20pt;letter-spacing:3px'>#{h(title)}</p></td>" \
        "<td style='background-color:#{c(:accent)};border:0;width:6%'><p style='margin:0'>&nbsp;</p></td><td style='border:0;width:14%'><p style='margin:0'>&nbsp;</p></td></tr></table>"
    end

    def kv(rows)
      cells = rows.map do |k, v|
        "<tr><td style='border:1px solid #{c(:primary)};padding:7pt;width:28%;vertical-align:top'><p style='#{font};margin:0;font-weight:700;color:#{c(:primary)};font-size:10pt'>#{h(k)}</p></td>" \
          "<td style='border:1px solid #{c(:primary)};padding:7pt;vertical-align:top'>#{v}</td></tr>"
      end
      "<table style='border-collapse:collapse;width:100%' width='100%'>#{cells.join}</table>"
    end

    def columns(pairs, rule: false)
      tds = pairs.first(2).each_with_index.map do |col, i|
        border = rule && i.zero? ? "border-right:3px solid #{c(:primary)};" : ""
        pad = i.zero? ? "0 12pt 0 0" : "0 0 0 12pt"
        "<td style='border:0;#{border}width:50%;vertical-align:top;padding:#{pad}'>" \
          "#{p(h(col[:title].upcase), "color:#{c(:primary)};font-weight:700;letter-spacing:2px;font-size:10pt")}#{p(h(col[:text]), 'font-size:10pt')}</td>"
      end
      "<table style='border-collapse:collapse;width:100%' width='100%'><tr>#{tds.join}</tr></table>"
    end

    def proposal_cover(pr)
      left = [p("PREPARED FOR", "font-weight:700;color:#{GREY};letter-spacing:2px;font-size:10pt;margin:0 0 4pt 0"),
              p(field("Contact name"), "margin:0"), p(field("Company"), "margin:0"), p(field("Address"), "margin:0")].join
      right = [p(field("PROJECT NAME"), "font-weight:700;letter-spacing:1px;margin:0", "right"),
               p("Proposal no. #{field(pr[:number_format] || "#{@spec.short}-YYYY-000")}", "margin:0", "right"),
               p("Date: #{field('Month D, YYYY')}", "margin:0", "right"), p("Prepared by: #{field('Your name')}", "margin:0", "right")].join
      <<~HTML
        <p style='text-align:center;margin:0'><img src='#{data_uri(@spec.logo_png(:full, :light))}' width='250'></p>
        #{p('PROPOSAL', "font-weight:700;color:#{c(:title)};font-size:40pt;letter-spacing:6px;margin:10pt 0 6pt 0", 'center')}
        <p style='text-align:center;margin:0'><img src='#{data_uri(@spec.slot(:proposal_cover))}' width='624'></p>
        #{p(h(pr[:credentials_line].to_s.upcase), "color:#{c(:primary)};font-weight:700;letter-spacing:2px;font-size:10.5pt;margin:12pt 0 14pt 0", 'center') if pr[:credentials_line]}
        <table style='border-collapse:collapse;width:100%' width='100%'><tr>
        <td style='border:0;border-left:4px solid #{c(:accent)};padding:0 0 0 10pt;width:50%;vertical-align:top'>#{left}</td>
        <td style='border:0;padding:0;width:50%;vertical-align:top'>#{right}</td></tr></table>#{gap}
      HTML
    end

    def about(pr)
      cols = Array(pr[:about_columns])
      band("ABOUT US") + photo(:proposal_about) + p(h(pr[:about] || @spec.one_sentence)) +
        p(h(@spec.tagline.delete_suffix(".").upcase), "font-weight:700;color:#{c(:accent)};letter-spacing:2px;margin:14pt 0 8pt 0") +
        (cols.any? ? columns(cols) : "") + motto(pr) + gap
    end

    def details(pr)
      rows = Array(pr[:details].presence || DEFAULT_DETAILS).map { |k, v| [k, p(field(v), "margin:0")] }
      steps = ->(s) { "<ul>#{s.map { |x| "<li style='#{font};font-size:10pt;color:#{INK}'>#{h(x)} <span style='color:#{GREY}'>— #{field('duration')}</span></li>" }.join}</ul>" }
      phases = Array(pr[:schedule].presence || DEFAULT_SCHEDULE).map do |ph|
        "<li style='#{font};font-size:10pt;color:#{INK}'><b>#{h(ph[:phase])}</b>#{steps.call(Array(ph[:steps]))}</li>"
      end
      schedule = "<ul style='margin:0'>#{phases.join}</ul>#{p("<b>Total project length: #{field('X–Y weeks')}</b>", 'margin:6pt 0 0 0')}"
      rows.insert([rows.size - 1, 1].max, ["Schedule", schedule])
      band("PROPOSAL DETAILS") + kv(rows) + motto(pr) + gap
    end

    def pricing(pr)
      th = ->(t, al = "left") { "<td style='background-color:#{c(:primary)};border:1px solid #{c(:primary)};padding:6pt'><p style='#{font};margin:0;color:#FFFFFF;font-weight:700;font-size:10pt;text-align:#{al}'>#{t}</p></td>" }
      td = ->(t, st = "") { "<td style='border:1px solid #{LINE};padding:6pt'><p style='#{font};margin:0;font-size:10pt;#{st}'>#{t}</p></td>" }
      lines = Array(pr[:pricing].presence || DEFAULT_PRICING).map do |item, detail|
        "<tr>#{td.call(h(item), "font-weight:700;color:#{INK}")}#{td.call(h(detail), "color:#{GREY}")}#{td.call(field('$0'), 'text-align:right')}</tr>"
      end
      total = "<tr><td style='border:1px solid #{c(:primary)};padding:7pt' colspan='2'><p style='#{font};margin:0;font-weight:700;color:#{c(:primary)}'>Total, applicable taxes included</p></td>" \
              "<td style='border:1px solid #{c(:primary)};padding:7pt'><p style='#{font};margin:0;font-weight:700;text-align:right;color:#{c(:primary)}'>#{field('$0')}</p></td></tr>"
      terms = Array(pr[:pricing_terms].presence || DEFAULT_TERMS).map { |k, v| [k, p(h(v), "margin:0")] }
      band("PRICING DETAILS") + p("<i>Pricing model: #{field(pr[:pricing_model] || 'Lump sum / Time and materials with an estimated budget')}</i>") +
        "<table style='border-collapse:collapse;width:100%' width='100%'><tr>#{th.call('Item')}#{th.call('Detail')}#{th.call('Amount', 'right')}</tr>#{lines.join}#{total}</table>" \
        "<p style='margin:10pt 0 0 0'></p>#{kv(terms)}#{motto(pr)}#{gap}"
    end

    def clients(pr)
      names = Array(pr[:clients])
      return nil if names.empty?

      rows = names.each_slice(4).map do |row|
        "<tr>#{row.map { |n| "<td style='border:1px solid #{LINE};padding:10pt;width:25%'><p style='#{font};margin:0;text-align:center;font-weight:700;color:#{c(:primary)};font-size:10pt'>#{h(n)}</p></td>" }.join}</tr>"
      end
      note = pr[:clients_note] ? p(h(pr[:clients_note]), "font-size:9pt;margin-top:8pt") : ""
      band("CLIENTS") + p("Selected clients we have worked with:") + "<table style='border-collapse:collapse;width:100%' width='100%'>#{rows.join}</table>" + note + motto(pr) + gap
    end

    def why(pr)
      cols = Array(pr[:why])
      return nil if cols.empty?

      contact = [@spec.contact[:phone], @spec.contact[:proposals_email] || @spec.contact[:email], @spec.contact[:website]].compact.map { |x| h(x) }.join(" · ")
      band("WHY CHOOSE US?") + photo(:proposal_why) + columns(cols, rule: true) +
        p(contact, "color:#{c(:primary)};font-weight:700;margin-top:18pt", "center") + gap
    end

    def acceptance(pr)
      sig = lambda do |who|
        "<td style='border:1px solid #{LINE};padding:10pt;width:50%;vertical-align:top'>#{p(h(who), "font-weight:700;color:#{c(:primary)};letter-spacing:2px;font-size:10pt")}" +
          %w[Signature Name Title Date].map { |l| p("#{l}: ______________________________", "margin:10pt 0 0 0;font-size:10pt") }.join + "</td>"
      end
      email = @spec.contact[:proposals_email] || @spec.contact[:email]
      band("ACCEPTANCE") +
        p("By signing below, the Client accepts this proposal (#{field('Proposal no.')}) for #{field('Project name')} in the amount of #{field('$0')}#{', and the Terms of Service that follow' if pr[:terms_of_service]}.") +
        "<table style='border-collapse:collapse;width:100%;margin-top:10pt' width='100%'><tr>#{sig.call('CLIENT')}#{sig.call(@spec.legal_name.upcase)}</tr></table>" +
        (email ? p("Please return a signed copy to #{h(email)}.", "margin-top:14pt;font-size:10pt") : "") + motto(pr) + gap
    end

    def terms_of_service(pr)
      tos = pr[:terms_of_service] or return nil
      small = "font-size:8.5pt;line-height:1.25;margin:0 0 4pt 0"
      items = Array(tos[:items]).map { |k, v| "<li style='#{font};font-size:8.5pt;line-height:1.25;color:#{INK};margin-bottom:3pt'><b>#{h(k)}.</b> #{h(v)}</li>" }
      band("TERMS OF SERVICE") + Array(tos[:intro]).map { |t| p(h(t), small) }.join + "<ol style='margin:0'>#{items.join}</ol>" + motto(pr)
    end
  end
end
