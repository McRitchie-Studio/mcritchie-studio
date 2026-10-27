# frozen_string_literal: true

module MarketingKit
  # The kit's own Google Docs: 00 Start Here (how the kit works), the Brand
  # Guide (logos, colour, type, photos, voice), and any further docs the brand
  # writes itself (Messaging, a Capabilities Statement, …), listed in the spec's
  # `docs:` as HTML fragments beside it. Each is a Doc-bound HTML page.
  class KitDocs
    include Html

    Doc = Data.define(:title, :folder, :html)

    HOUSE_RULES = [
      "<b>One source of truth.</b> Link to files in this folder; do not email copies around. Replace a file in place (Manage versions) so links keep working.",
      "<b>Log every change</b> in the tracker's Asset Inventory tab: what, who, when, status.",
      "<b>Name files</b> <code>%<short>s_&lt;type&gt;_&lt;subject&gt;_&lt;variant&gt;</code>, e.g. <code>%<short>s_logo_horizontal_dark.png</code>.",
      "<b>Nothing confidential lives here.</b> This kit is meant to be shared.",
      "<b>Claims need proof.</b> Every certification or number we print must be current and documented."
    ].freeze

    def initialize(spec)
      @spec = spec
      @styler = DocStyler.new(spec)
    end

    def start_here = Doc.new("00 Start Here", Layout::ROOT, @styler.page(start_here_body))
    def brand_guide = Doc.new("Brand Guide", Layout::BRAND, @styler.page(brand_guide_body))

    def extras
      Array(@spec.data[:docs]).map do |d|
        raise Error, "docs entry needs a title, a folder and a file" unless d[:title].present? && d[:folder].present? && d[:file].present?
        raise Error, "docs entry #{d[:title]}: unknown folder #{d[:folder]}" unless Layout::FOLDERS.include?(d[:folder])

        path = File.expand_path(d[:file], @spec.root)
        raise Error, "docs entry #{d[:title]}: no file at #{path}" unless File.file?(path)

        Doc.new(d[:title], d[:folder], @styler.page(File.read(path)))
      end
    end

    def all = [start_here, brand_guide, *extras]

    private

    def start_here_body
      sh = @spec.start_here
      rows = [["00 Start Here (this doc)", "How the kit works", "Read first"],
              ["Marketing Kit Tracker (sheet)", "Asset inventory, channels, backlog", "Find any asset; request a new one; track status"],
              ["#{h(@spec.short)} Brand Guidelines.pdf", "Four-page quick reference: logos, colours, fonts, our lines, photos, ideas", "Share with anyone making something for us"],
              ["Quick-grab files (top level)", "Copies of the most-used logos and favourite photos", "Grab-and-go. The masters live in #{Layout::BRAND} and #{Layout::PHOTOS}"]] +
             Layout::PURPOSE.map { |folder, what| [folder, h(what), ""] } +
             Array(sh[:rows]).map { |r| r.map { |x| h(x) } }
      <<~HTML
        <h1>#{h(@spec.root_name)}</h1>
        <p><b>Owner:</b> #{h(@spec.owner)}. <b>Updated:</b> #{h(@spec.updated)}.#{" #{h(sh[:status])}" if sh[:status]}</p>
        <p>This folder is the one home for everything used to market #{h(@spec.name)}: logos, photographs, approved copy, templates and sales collateral. If it is not here, it is not approved. If you make or change an asset, put it here and log it in the <b>Marketing Kit Tracker</b>.</p>
        <h2>What is where</h2>
        #{table(['Folder / file', 'What it holds', 'Use it for'], rows)}
        <h2>House rules</h2>
        <ol>#{HOUSE_RULES.map { |r| "<li>#{format(r, short: h(@spec.short))}</li>" }.join}</ol>
        #{sh[:extra_html]}
        <h2>How to ask for something new</h2>
        <p>Add a row to the tracker's <b>Backlog</b> tab: what you need, for what, by when.</p>
      HTML
    end

    def brand_guide_body
      bg = @spec.brand_guide
      f = @spec.fonts
      logo_rows = [["Stacked, with tagline", "#{@spec.short}_logo_full_light / _dark", "Covers, signage, title slides"],
                   ["Horizontal", "#{@spec.short}_logo_horizontal_light / _dark", "Website header, letterhead, email signature, proposals"],
                   ["Icon", "#{@spec.short}_logo_icon_light / _dark; #{@spec.short}_logo_icon_512.png", "Social avatars, favicons, stickers, apparel"]]
      colour_rows = @spec.palette.map { |s| [h(s[:name]), s[:hex].upcase, rgb(s[:hex]), h(s[:role])] }
      <<~HTML
        <h1>#{h(@spec.name)} Brand Guide</h1>
        #{"<p>#{h(bg[:intro])}</p>" if bg[:intro]}
        <h2>Name</h2>
        <ul><li><b>In copy:</b> #{h(@spec.name)}.#{" Use the full legal name, #{h(@spec.legal_name)}, in contracts and formal documents." if @spec.legal_name != @spec.name}</li>
        <li><b>Tagline:</b> #{h(@spec.tagline.delete_suffix('.').upcase)} (in capitals when set with the logo; “#{h(@spec.tagline.delete_suffix('.'))}” in running text).</li></ul>
        <h2>Logos</h2>
        #{table(['Logo', "Files (#{Layout::BRAND} / Logos)", 'Use'], logo_rows)}
        <p><b>_light</b> files are drawn for light backgrounds; <b>_dark</b> files for dark backgrounds. Use SVG for print and the web; use PNG for Word, PowerPoint and social uploads.</p>
        #{bg[:logo_notes_html]}
        <h2>Colour</h2>
        #{table(%w[Name HEX RGB Role], colour_rows)}
        <h2>Type</h2>
        <ul><li><b>Headings:</b> #{h(f[:family])} at weight #{f[:heading]}. <b>Subheads, accents and the tagline:</b> weight #{f[:subhead]}. <b>Body:</b> weight #{f[:body]}, or #{h(f[:fallback])} where #{h(f[:family])} is not available.</li>
        #{"<li>#{h(f[:note])}</li>" if f[:note]}</ul>
        <h2>Photography</h2>
        <p>#{h(@spec.photo_style || 'Real work by our own people, never stock.')} The approved set is in #{Layout::PHOTOS}; the tracker lists each photo's subject.</p>
        <h2>Voice</h2>
        <p>#{h(@spec.voice)}</p>
      HTML
    end
  end
end
