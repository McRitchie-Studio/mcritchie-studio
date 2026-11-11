# frozen_string_literal: true

module MarketingKit
  # The standard shape of a kit in Drive, the same for every brand, so a person
  # who knows one kit can find their way round any other. Folder paths are
  # slash-joined names under the kit's root folder; "" is the root itself.
  module Layout
    ROOT = ""
    BRAND = "01 Brand"
    LOGOS_SVG = "01 Brand/Logos/SVG — print and web"
    LOGOS_PNG = "01 Brand/Logos/PNG — Office and social"
    # The spec and its doc fragments, so anyone can rebuild the kit from Drive alone.
    SOURCE = "01 Brand/Kit source"
    PHOTOS = "02 Photography"
    MESSAGING = "03 Messaging"
    COLLATERAL = "04 Sales Collateral"
    TEMPLATES = "05 Templates"
    ARCHIVE = "06 Archive"

    FOLDERS = [BRAND, "01 Brand/Logos", LOGOS_SVG, LOGOS_PNG, SOURCE, PHOTOS, MESSAGING, COLLATERAL, TEMPLATES, ARCHIVE].freeze

    # What each top-level folder holds, for 00 Start Here and the guidelines'
    # "where things are" table.
    PURPOSE = {
      BRAND => "Brand Guide; every logo file (SVG for print and web, PNG for Office and social); the kit spec",
      PHOTOS => "Approved photographs",
      MESSAGING => "Company descriptions, taglines, services, proof points, contact block",
      COLLATERAL => "Capabilities statements and other sales pieces",
      TEMPLATES => "Doc, Proposal, Slides and Sheet templates (File, then Make a copy)",
      ARCHIVE => "Superseded files. Move, never delete"
    }.freeze

    def self.top_level(path) = path.split("/").first

    # Every kit template is named "<SHORT> <Kind> Template" (MS Sheet Template,
    # MI Doc Template, CW Proposal Template), so anyone in the organisation,
    # person or agent, reads what it is from the name alone. Alex McRitchie's
    # naming ruling, 2026-11-10.
    TEMPLATE_KINDS = { doc: "Doc", proposal: "Proposal", slides: "Slides", sheet: "Sheet" }.freeze

    def self.template_name(short, kind) = "#{short} #{TEMPLATE_KINDS.fetch(kind)} Template"

    # The name a template carried before that ruling ("MS Template — General"),
    # which the publisher renames in place so links and gallery entries survive.
    LEGACY_KIND = { "Doc" => "General", "Proposal" => "Proposal", "Slides" => "Slides", "Sheet" => "Sheet" }.freeze

    def self.legacy_template_name(name)
      m = name.match(/\A(\w+) (#{TEMPLATE_KINDS.values.join('|')}) Template\z/) or return nil
      "#{m[1]} Template — #{LEGACY_KIND.fetch(m[2])}"
    end
  end
end
