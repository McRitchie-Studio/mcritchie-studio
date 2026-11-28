# frozen_string_literal: true

module MarketingKit
  # The General Doc template every kit carries: a newsletter-style branded page,
  # HTML for Drive's Doc import, so styles are inline and images are data URIs.
  # The Proposal template needs page breaks, which Drive's HTML import drops, so
  # it is a Word file (ProposalTemplate, drawn by script/marketing_kit/office.py).
  class DocTemplates
    include Html

    INK = "#1F2933"
    GREY = "#6B7785"

    def initialize(spec)
      @spec = spec
    end

    def general_name = Layout.template_name(@spec.short, :doc)

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

    private

    def c(key) = @spec.colour(key)
    def font = "font-family:#{@spec.fonts[:family]},#{@spec.fonts[:fallback]},sans-serif"
    def doc(body) = "<html><head><meta charset='utf-8'></head><body style='#{font}'>#{body}</body></html>"

    def p(text, style = "", align = "left")
      "<p style='#{font};text-align:#{align};color:#{INK};font-size:10.5pt;line-height:1.35;margin:0 0 6pt 0;#{style}'>#{text}</p>"
    end


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

  end
end
