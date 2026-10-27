# frozen_string_literal: true

require "fileutils"
require "json"

module MarketingKit
  # Renders a whole kit into one local folder and writes manifest.json: every
  # file the kit carries, where it goes in Drive and what Drive should make of
  # it. Nothing here touches Drive; Publisher reads the manifest.
  #
  #   build = MarketingKit::Build.new(spec, out: "tmp/kit").run
  #   build.entries.map(&:name)  # => ["00 Start Here", "Brand Guide", …]
  class Build
    # kind: "doc" (HTML → Google Doc), "sheet" (xlsx → Google Sheet),
    # "slides" (pptx → Google Slides) or "file" (uploaded as it is).
    Entry = Data.define(:local, :name, :folder, :kind, :type, :about)

    MIME = { ".svg" => "image/svg+xml", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
             ".pdf" => "application/pdf", ".yml" => "text/plain", ".yaml" => "text/plain", ".html" => "text/html" }.freeze

    TRACKER = "Marketing Kit Tracker"

    attr_reader :spec, :out, :entries

    # pdf: false and office: false skip the two steps that need Chrome and
    # Python, so the rest renders anywhere (tests, CI).
    def initialize(spec, out:, pdf: true, office: true)
      @spec = spec
      @out = File.expand_path(out)
      @pdf = pdf
      @office = office
      @entries = []
    end

    def run
      FileUtils.mkdir_p(%w[docs templates guidelines].map { |d| File.join(out, d) })
      kit_docs
      templates
      guidelines
      logos
      photos
      source
      tracker
      File.write(File.join(out, "manifest.json"), JSON.pretty_generate(entries.map(&:to_h)))
      self
    end

    def self.mime(path) = MIME.fetch(File.extname(path).downcase) { raise Error, "no MIME type for #{path}" }

    private

    def add(local, name, folder, kind, type, about) = entries << Entry.new(local, name, folder, kind, type, about)

    def write(dir, name, body) = File.join(out, dir, "#{name}.html").tap { |p| File.write(p, body) }

    def kit_docs
      KitDocs.new(spec).all.each do |doc|
        about = { "00 Start Here" => "Kit index and house rules", "Brand Guide" => "Logo, colour, type, photo and voice guide" }
        add(write("docs", doc.title, doc.html), doc.title, doc.folder, "doc", "Guide", about.fetch(doc.title, "Written for this brand"))
      end
    end

    def templates
      t = DocTemplates.new(spec)
      add(write("templates", t.general_name, t.general), t.general_name, Layout::TEMPLATES, "doc", "Template",
          "General branded document: logo, title, photo, sections, call-to-action button, footer. File, then Make a copy")
      add(write("templates", t.proposal_name, t.proposal), t.proposal_name, Layout::TEMPLATES, "doc", "Template",
          "Customer proposal: cover, about us, details, pricing, why us, acceptance. Fill the orange [fields]")
      return unless @office

      o = Office.new(spec)
      add(o.write_slides(File.join(out, "templates", "#{o.slides_name}.pptx")), o.slides_name, Layout::TEMPLATES, "slides", "Template",
          "12-slide branded deck. Duplicate the slides you need; right-click a photo, then Replace image")
    end

    def guidelines
      g = Guidelines.new(spec)
      html = write("guidelines", "guidelines", g.html)
      return unless @pdf

      add(ChromePdf.print(html, File.join(out, "guidelines", "#{g.title}.pdf")), "#{g.title}.pdf", Layout::ROOT, "file", "Guide",
          "Four-page quick reference: logos, colours, fonts, lines, photos, ideas")
    end

    def logos
      spec.logo_files.each do |path, name|
        folder = File.extname(path) == ".svg" ? Layout::LOGOS_SVG : Layout::LOGOS_PNG
        add(path, name, folder, "file", "Logo", File.basename(path, ".*").tr("_", " "))
      end
      spec.quick_grab_logos.each do |base|
        path = File.join(spec.logos_dir, "png", base)
        raise Error, "quick-grab logo #{base} is not in #{spec.logos_dir}/png" unless File.file?(path)

        add(path, "#{spec.short}_logo_#{base}", Layout::ROOT, "file", "Quick-grab", "Top-level copy of the master in #{Layout::LOGOS_PNG}")
      end
    end

    def photos
      spec.photos.each { |ph| add(spec.photo_path(ph[:file]), spec.photo_name(ph[:file]), Layout::PHOTOS, "file", "Photo", ph[:subject]) }
      spec.favourite_photos.each do |f|
        add(spec.photo_path(f), spec.photo_name(f), Layout::ROOT, "file", "Quick-grab", "Top-level copy of the master in #{Layout::PHOTOS}")
      end
    end

    def source
      return unless spec.path

      add(spec.path, "#{spec.short} Kit Spec.yml", Layout::SOURCE, "file", "Source", "The kit spec: rebuild the kit from it (marketing-kit SOP)")
      Array(spec.data[:docs]).each do |d|
        add(File.expand_path(d[:file], spec.root), File.basename(d[:file]), Layout::SOURCE, "file", "Source", "Source of #{d[:title]}")
      end
    end

    def tracker
      inventory = entries.map do |e|
        format = { "doc" => "Google Doc", "sheet" => "Google Sheet", "slides" => "Google Slides" }.fetch(e.kind) { File.extname(e.local).delete(".").upcase }
        [e.type, e.folder.presence || "(root)", e.name, format, e.about, "Approved", spec.owner, spec.updated, ""]
      end
      inventory.unshift(["Guide", "(root)", TRACKER, "Google Sheet", "This tracker", "Approved", spec.owner, spec.updated, ""])
      path = File.join(out, "#{TRACKER}.xlsx")
      if @office
        Office.new(spec).write_tracker(inventory, path)
        entries.unshift(Entry.new(path, TRACKER, Layout::ROOT, "sheet", "Guide", "This tracker"))
      else
        File.write("#{path}.json", JSON.pretty_generate(Office.new(spec).tracker_payload(inventory)))
      end
    end
  end
end
