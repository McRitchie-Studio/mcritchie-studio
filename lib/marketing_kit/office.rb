# frozen_string_literal: true

require "json"
require "open3"
require "digest"

module MarketingKit
  # The two Office files: the 12-slide template (.pptx, which Drive converts to
  # Google Slides) and the tracker workbook (.xlsx, converted to a Google
  # Sheet). Ruby decides every word and colour here and writes a JSON payload;
  # script/marketing_kit/office.py only draws it (python-pptx and openpyxl,
  # which have no Ruby equivalent good enough for Drive's import).
  class Office
    SCRIPT = File.expand_path("../../script/marketing_kit/office.py", __dir__)
    REQUIREMENTS = File.expand_path("../../script/marketing_kit/requirements.txt", __dir__)

    def initialize(spec)
      @spec = spec
    end

    def slides_name = "#{@spec.short} Template — Slides"

    def slides_payload
      s = @spec.slides
      name = @spec.name
      {
        font: @spec.fonts[:family],
        colours: %i[primary title accent accent_on_dark primary_deep dark].to_h { |k| [k, @spec.colour(k)] }
                                                                       .merge(white: "#FFFFFF", grey: "#5A6675", light: "#F3F5F8", rule: "#D9DEE5"),
        images: {
          logo_full_dark: @spec.logo_png(:full, :dark), logo_horizontal_light: @spec.logo_png(:horizontal, :light),
          logo_horizontal_dark: @spec.logo_png(:horizontal, :dark), logo_icon_light: @spec.logo_png(:icon, :light),
          cover: @spec.slot(:slide_cover), half: @spec.slot(:slide_half), full: @spec.slot(:slide_full),
          spot: @spec.slot(:slide_spot), quote: @spec.slot(:slide_quote)
        },
        agenda: s[:agenda] || ["[Who we are]", "[The project]", "[Our approach]", "[Schedule and next steps]"],
        points_title: s[:points_title] || "[Why #{name}]",
        points: s[:points] || [["[Big number]", "[Point one]", "[One line of proof]"], ["[100%]", "[Point two]", "[One line of proof]"],
                               ["[Fact]", "[Point three]", "[One line of proof]"]],
        spotlight: s[:spotlight] || [["Client", "[Client name]"], ["Location", "[City, State]"], ["Scope", "[What we delivered]"],
                                     ["Details", "[Materials, sizes, numbers]"], ["Result", "[On schedule · on budget]"]],
        timeline: s[:timeline] || [["Start", "[Week 1]", "[Kick-off and planning]"], ["Build", "[Weeks 2–4]", "[The main work]"],
                                   ["Check", "[Week 5]", "[Testing and review]"], ["Finish", "[Week 6]", "[Handover]"]],
        pricing: s[:pricing] || [["[Item one]", "[Description]"], ["[Item two]", "[Description]"], ["[Item three]", "[Description]"],
                                 ["[Item four]", "[Description]"]],
        contact: Array(s[:contact] || [@spec.contact[:phone], @spec.contact[:proposals_email] || @spec.contact[:email],
                                       @spec.contact[:website], @spec.contact[:address]]).compact
      }
    end

    def tracker_payload(inventory)
      tr = @spec.tracker
      sheets = [
        { title: "Asset Inventory", head: ["Type", "Folder", "File", "Format", "Description / use", "Status", "Owner", "Updated", "Source / notes"],
          rows: inventory, widths: [11, 20, 34, 12, 52, 24, 16, 12, 44] },
        { title: "Channels", head: ["Channel", "Handle / URL", "Status", "Owner", "Notes"], rows: Array(tr[:channels]), widths: [34, 40, 12, 26, 70] },
        { title: "Backlog", head: ["Item", "Why", "Priority", "Requested by", "Due", "Status"], rows: Array(tr[:backlog].presence || default_backlog),
          widths: [50, 60, 10, 16, 12, 10] }
      ]
      if tr[:claims].present?
        sheets << { title: "Claims to Review", head: ["Claim", "Where it appears", "Issue", "Action", "Status"], rows: tr[:claims],
                    widths: [44, 40, 46, 40, 16] }
      end
      { font: @spec.fonts[:family], header_fill: @spec.colour(:primary).delete("#"), sheets: sheets.map { |sh| sh.merge(rows: sh[:rows].map { |r| Array(r).map(&:to_s) }) } }
    end

    def write_slides(path) = draw("slides", slides_payload, path)
    def write_tracker(inventory, path) = draw("tracker", tracker_payload(inventory), path)

    # The venv lives outside the tree so a desk and the primary share it; it is
    # rebuilt only when requirements.txt changes.
    def self.python
      @python ||= begin
        dir = File.join(Dir.home, ".cache", "marketing-kit", Digest::SHA256.file(REQUIREMENTS).hexdigest[0, 12])
        bin = File.join(dir, "bin", "python")
        unless File.executable?(bin)
          run!("python3", "-m", "venv", dir)
          run!(bin, "-m", "pip", "install", "--quiet", "-r", REQUIREMENTS)
        end
        bin
      end
    end

    def self.run!(*cmd)
      out, status = Open3.capture2e(*cmd)
      raise Error, "#{cmd.first(3).join(' ')} failed:\n#{out}" unless status.success?

      out
    end

    private

    def draw(kind, payload, path)
      json = "#{path}.json"
      File.write(json, JSON.pretty_generate(payload))
      self.class.run!(self.class.python, "-I", SCRIPT, kind, json, path)
      path
    end

    def default_backlog
      [["Email signature (HTML + plain)", "Every email; uses the horizontal logo", "High", @spec.owner, "", "Open"],
       ["Business card", "The team, in person", "High", @spec.owner, "", "Open"],
       ["Letterhead", "Letters and quotes", "Medium", @spec.owner, "", "Open"],
       ["Case studies (3)", "Proposals and the website", "Medium", @spec.owner, "", ""]]
    end
  end
end
