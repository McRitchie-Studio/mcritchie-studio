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
      TEMPLATES => "General document, proposal and slideshow templates (File, then Make a copy)",
      ARCHIVE => "Superseded files. Move, never delete"
    }.freeze

    def self.top_level(path) = path.split("/").first
  end
end
