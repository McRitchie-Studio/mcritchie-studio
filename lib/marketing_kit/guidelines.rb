# frozen_string_literal: true

module MarketingKit
  # The four-page brand guidelines (cover; logos and colours; fonts and words;
  # photos and ideas) as one printable HTML page. Alex McRitchie's brief,
  # 2026-10-26: "No need to be militant about everything. I mainly want easy
  # access to the information and ideas." So it is a reference, not a rulebook.
  # Images are file:// links; ChromePdf prints it with file access on.
  class Guidelines
    include Html

    def initialize(spec)
      @spec = spec
    end

    def title = "#{@spec.short} Brand Guidelines"

    def html
      <<~HTML
        <!doctype html><html><head><meta charset="utf-8"><title>#{h(@spec.name)} Brand Guidelines</title>
        <link href="https://fonts.googleapis.com/css2?family=#{@spec.fonts[:family].tr(' ', '+')}:wght@400;700;800&display=block" rel="stylesheet">
        <style>#{css}</style></head><body>#{cover}#{logos_and_colours}#{fonts_and_words}#{photos_and_ideas}</body></html>
      HTML
    end

    private

    def c(key) = @spec.colour(key)
    def img(path) = file_url(path)

    def page(body, n, kicker)
      "<section class='page'><div class='kicker'>#{h(kicker)}</div>#{body}" \
        "<div class='foot'><span>#{h(@spec.name)} · Brand Guidelines</span><span>#{format('%02d', n)}</span></div></section>"
    end

    def cover
      "<section class='page cover'><div class='cover-photo'></div><div class='cover-body'>" \
        "<img class='cover-logo' src='#{img(@spec.logo_png(:full, :dark))}'><h1 class='cover-title'>Brand Guidelines</h1>" \
        "<p class='cover-sub'>The logos, colours, fonts and words, in one place</p></div></section>"
    end

    def logos_and_colours
      page(<<~HTML, 2, "Logos · Colours")
        <h2>Logos and colours</h2>
        <p class='lede'>Grab the logo files from the top of the Marketing Kit folder. Use the <b>light</b> version on white and the <b>dark</b> version on dark backgrounds or photos.</p>
        <div class='logos'>
          <div class='lk light'><img src='#{img(@spec.logo_png(:full, :light))}'><p>Stacked<br><span>Covers, signs, title slides</span></p></div>
          <div class='lk light'><img src='#{img(@spec.logo_png(:horizontal, :light))}' class='wide'><p>Horizontal<br><span>Letterhead, proposals, email, website</span></p></div>
          <div class='lk light'><img src='#{img(@spec.logo_png(:icon, :light))}'><p>Icon<br><span>Profile pictures, stickers, shirts</span></p></div>
          <div class='lk dark'><img src='#{img(@spec.logo_png(:full, :dark))}'><p>Dark versions<br><span>For dark backgrounds or photos</span></p></div>
        </div>
        <p class='tip'>PNG works for Word, Slides, Canva and social posts. Send printers and sign shops the SVG from 01 Brand › Logos.</p>
        <h3>Colours</h3>
        <div class='swgrid' style='grid-template-columns:repeat(#{@spec.palette.size},1fr)'>#{@spec.palette.map { |s| chip(s) }.join}</div>
        #{"<p class='tip'>#{h(@spec.data[:colour_tip])}</p>" if @spec.data[:colour_tip]}
      HTML
    end

    def chip(swatch)
      hex = swatch[:hex].upcase
      "<div class='sw'><div class='chip' style='background:#{hex};color:#{light?(hex) ? c(:dark) : '#fff'}'>" \
        "<b>#{h(swatch[:name])}</b><span>#{h(swatch[:role])}</span></div><p><b>#{hex}</b><br>RGB #{rgb(hex)}</p></div>"
    end

    def fonts_and_words
      f = @spec.fonts
      lines = [["Tagline", "<span class='tag'>#{h(@spec.tagline.delete_suffix('.').upcase)}</span>"]] +
              @spec.lines.map { |l| [h(l[:label]), h(l[:text])] }
      page(<<~HTML, 3, "Fonts · Words")
        <h2>Fonts and words</h2>
        <div class='fonts'>
          <div><p class='big' style='font-weight:#{f[:heading]};color:#{c(:title)}'>#{h(f[:family])} #{weight_name(f[:heading])}</p><p>Headings</p></div>
          <div><p class='big' style='font-weight:#{f[:subhead]};color:#{c(:accent)}'>#{h(f[:family].upcase)} #{weight_name(f[:subhead]).upcase}</p><p>Subheads and the tagline</p></div>
          <div><p class='big' style='font-weight:#{f[:body]}'>#{h(f[:family])} #{weight_name(f[:body])}</p><p>Everything else</p></div>
        </div>
        <p class='tip'>#{h(f[:note] || "#{f[:family]} is free and already in Google Docs, Slides and Canva. #{f[:fallback]} is fine when it isn't available.")}</p>
        <h3>Lines we use</h3>
        <table class='lines'>#{lines.map { |k, v| "<tr><td>#{k}</td><td>#{v}</td></tr>" }.join}</table>
        <h3>In a sentence</h3><p class='quote'>#{h(@spec.one_sentence)}</p>
        <h3>Elevator pitch</h3><p class='quote'>#{h(@spec.pitch)}</p>
        <h3>How we sound</h3><p>#{h(@spec.voice)}</p>
        <h3>Contact</h3><p class='contact'>#{Array(@spec.contact[:lines]).map { |l| h(l) }.join('<br>')}</p>
      HTML
    end

    def photos_and_ideas
      grid = @spec.guideline_photos.map { |f| "<div class='ph' style=\"background-image:url('#{img(@spec.photo_path(f))}')\"></div>" }.join
      ideas = @spec.ideas.map { |i| "<div><b>#{h(i[:title])}</b><p>#{h(i[:text])}</p></div>" }.join
      page(<<~HTML, 4, "Photos · Ideas")
        <h2>Photos and ideas</h2>
        <p class='lede'>Our own work is the best marketing we have. #{@spec.photos.size} photos are in 02 Photography; #{@spec.favourite_photos.size} favourites are at the top of the folder.</p>
        <div class='photos'>#{grid}</div>
        #{"<h3>Ideas</h3><div class='ideas'>#{ideas}</div>" if ideas.present?}
        <h3>Where things are</h3>
        <table class='lines'>#{where_things_are.map { |k, v| "<tr><td>#{h(k)}</td><td>#{h(v)}</td></tr>" }.join}</table>
      HTML
    end

    def where_things_are
      [["Logos and favourite photos", "Top of the Marketing Kit folder"],
       ["All logo files (SVG for print)", "01 Brand › Logos"],
       ["All photos", Layout::PHOTOS],
       ["Company descriptions, services, proof points", Layout::MESSAGING],
       ["Capabilities and sales pieces", Layout::COLLATERAL],
       ["Proposal, slideshow and general templates", "#{Layout::TEMPLATES} (File › Make a copy)"],
       ["Ideas and requests", "Marketing Kit Tracker › Backlog"]]
    end

    def weight_name(w) = { 400 => "Regular", 500 => "Medium", 600 => "SemiBold", 700 => "Bold", 800 => "ExtraBold", 900 => "Black" }.fetch(w, w.to_s)

    def css
      <<~CSS
        @page { size: Letter; margin: 0; }
        * { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { margin:0; font-family:'#{@spec.fonts[:family]}',#{@spec.fonts[:fallback]},sans-serif; color:#{c(:dark)}; font-size:10pt; line-height:1.45; }
        .page { width:8.5in; height:11in; padding:.7in .8in .9in; position:relative; overflow:hidden; break-after:page; }
        .page:last-child { break-after:auto; }
        .page::before { content:''; position:absolute; left:0; top:0; width:100%; height:.12in; background:#{c(:primary)}; }
        .page::after { content:''; position:absolute; left:.8in; top:.12in; width:.9in; height:.06in; background:#{c(:accent)}; }
        .kicker { font-weight:700; color:#{c(:accent)}; letter-spacing:.14em; text-transform:uppercase; font-size:8.5pt; margin-bottom:.08in; }
        h2 { font-weight:800; color:#{c(:title)}; font-size:26pt; line-height:1.1; margin:0 0 .14in; }
        h3 { font-weight:700; color:#{c(:accent)}; text-transform:uppercase; letter-spacing:.08em; font-size:10pt; margin:.22in 0 .08in; }
        p { margin:0 0 .06in; }
        .lede { font-size:11pt; max-width:6.6in; margin-bottom:.16in; }
        .tip { font-size:9pt; color:#5a6675; margin-top:.1in; }
        .foot { position:absolute; left:.8in; right:.8in; bottom:.4in; display:flex; justify-content:space-between; font-size:7.5pt; color:#7d8794; border-top:1px solid #e3e7ec; padding-top:.08in; }
        .cover { background:#{c(:dark)}; color:#fff; padding:0; } .cover::after { display:none; }
        .cover-photo { position:absolute; inset:0; background:url('#{img(@spec.slot(:guidelines_cover))}') center/cover; opacity:.42; }
        .cover-body { position:absolute; left:0; right:0; top:2.4in; text-align:center; }
        .cover-logo { width:4.6in; }
        .cover-title { font-weight:800; font-size:38pt; margin:.45in 0 .1in; }
        .cover-sub { font-weight:700; color:#{c(:accent_on_dark)}; font-size:11pt; }
        .logos { display:grid; grid-template-columns:1fr 1fr; gap:.14in; }
        .lk { height:2.05in; display:flex; flex-direction:column; align-items:center; justify-content:center; padding:.15in; text-align:center; }
        .lk img { height:1.15in; } .lk img.wide { height:auto; width:2.9in; margin:.3in 0; }
        .lk p { font-weight:800; color:#{c(:primary)}; font-size:9.5pt; margin:.12in 0 0; line-height:1.3; }
        .lk p span { font-weight:400; color:#5a6675; font-size:8pt; }
        .lk.light { background:#fff; border:1px solid #d9dee5; } .lk.dark { background:#{c(:dark)}; }
        .lk.dark p { color:#fff; } .lk.dark p span { color:#c9d2dc; }
        .swgrid { display:grid; gap:.1in; }
        .chip { height:.85in; padding:.08in; display:flex; flex-direction:column; justify-content:flex-end; }
        .chip b { font-weight:800; font-size:8.5pt; } .chip span { font-size:7pt; opacity:.85; }
        .sw p { font-size:7.5pt; margin-top:.05in; color:#5a6675; } .sw p b { color:#{c(:dark)}; }
        .fonts { display:grid; grid-template-columns:repeat(3,1fr); gap:.12in; }
        .fonts > div { background:#f6f7f9; padding:.14in; } .fonts p:last-child { font-size:8.5pt; color:#5a6675; }
        .big { font-size:13pt; line-height:1.2; margin-bottom:.06in; }
        .lines { width:100%; border-collapse:collapse; font-size:9.5pt; }
        .lines td { padding:.06in .1in .06in 0; border-bottom:1px solid #e3e7ec; vertical-align:top; }
        .lines td:first-child { font-weight:700; color:#{c(:primary)}; width:2.6in; }
        .tag { font-weight:700; color:#{c(:accent)}; letter-spacing:.1em; }
        .quote { font-size:10.5pt; border-left:4px solid #{c(:primary)}; padding-left:.14in; color:#{c(:primary_deep)}; }
        .contact { font-size:9.5pt; }
        .photos { display:grid; grid-template-columns:repeat(3,1fr); grid-auto-rows:1.35in; gap:.07in; }
        .ph { background-size:cover; background-position:center; }
        .ideas { display:grid; grid-template-columns:repeat(3,1fr); gap:.1in; }
        .ideas > div { background:#f6f7f9; border-top:3px solid #{c(:accent)}; padding:.1in .12in; }
        .ideas b { color:#{c(:title)}; font-weight:800; font-size:9.5pt; } .ideas p { font-size:8.5pt; margin:.03in 0 0; }
      CSS
    end
  end
end
