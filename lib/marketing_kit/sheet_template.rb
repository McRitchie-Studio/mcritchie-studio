# frozen_string_literal: true

module MarketingKit
  # The kit's standard spreadsheet, `<SHORT> Template — Sheet`: margins on row 1
  # and column A, the brand icon in A2 with the title beside it on a row of its
  # own, a Last Updated line under the title beside the variables, then a table
  # whose two-row head is split into three colour sections. Ruby decides every colour and
  # word here; script/marketing_kit/office.py only lays the payload out as an
  # .xlsx, which Drive converts to a Google Sheet.
  #
  # The rules the layout keeps, because they are what make a sheet easy to work in:
  # - no merged cells anywhere, so columns and rows move freely;
  # - the freeze (C9) sits under the table's lower head and right of the item column,
  #   so the head and the row's item stay in view while you scroll;
  # - both head rows carry white text at WCAG AA or better (4.5:1).
  #
  #   SheetTemplate.new(spec).sections.map(&:top)  # => ["#1B1D22", "#7E4014", "#3E434A"]
  class SheetTemplate
    # White text needs 4.5:1 for WCAG AA; the lower head aims a hair above it, so
    # rounding to a hex never lands under.
    MIN_CONTRAST = 4.5
    LOW_TARGET = 4.6
    # A near-black colour (Charcoal, say) lightens its lower head to this, so the
    # step from the top head still shows.
    LOW_CEILING = 11.0
    # How far the top head goes from the lower head toward black.
    TOP_DARKEN = 0.30
    # The keys that are shades of primary or accent, never a third colour of their own.
    SHADE_KEYS = %i[accent_on_dark primary_deep accent_deep title].freeze

    WHITE = "#FFFFFF"
    INK = "#141516"
    GREY = "#5A6675"
    LIGHT = "#F3F5F8"
    RULE = "#D9DEE5"

    Section = Data.define(:name, :base, :top, :low)

    def initialize(spec)
      @spec = spec
    end

    def name = "#{@spec.short} Template — Sheet"

    # The three head sections: the spec's sheet.sections (swatch names or palette
    # keys), else primary, accent and the first other swatch that carries white text.
    def sections
      @sections ||= section_swatches.map do |swatch|
        low = self.class.legible(swatch[:hex].upcase)
        Section.new(name: swatch[:name], base: swatch[:hex].upcase, top: self.class.mix(low, "#000000", TOP_DARKEN), low: low)
      end
    end

    # The sheet's title is dark: the brand's primary unless sheet.title names a
    # swatch. The headline number keeps the brand's title colour (MI: a Charcoal
    # title over a Forge Orange total).
    def title_colour = @spec.sheet[:title] ? swatch(@spec.sheet[:title])[:hex].upcase : @spec.colour(:primary)

    # The icon in A2: sheet.icon picks the colourful version a brand has (MS's
    # violet chest is its dark-ground icon); light, the plain mark, by default.
    def icon = @spec.logo_png(:icon, (@spec.sheet[:icon] || "light").to_sym)

    # Where the title sits in row 2: centre, level with the icon's middle, unless
    # a brand's icon reads better with the title on its baseline (MI's set
    # square: sheet.title_align: bottom).
    def title_align = (@spec.sheet[:title_align] || "center").to_s

    # The day the sheet is built, in Denver, where the businesses are.
    def today = Time.current.in_time_zone("America/Denver").to_date

    # "Nov 10th, 2026": the Last Updated line an agent stamps at every build.
    def self.stamp(date) = "#{date.strftime('%b')} #{date.day.ordinalize}, #{date.year}"

    def payload
      {
        font: @spec.fonts[:family],
        sheet_title: "Sheet",
        colours: { title: title_colour, headline: @spec.colour(:title), white: WHITE, ink: INK, grey: GREY, light: LIGHT, rule: RULE },
        icon: icon,
        title: "[Sheet Title]",
        title_align: title_align,
        updated: self.class.stamp(today),
        sections: sections.each_with_index.map { |s, i| { label: "[Section #{%w[One Two Three][i]}]", top: s.top, low: s.low } },
        columns: COLUMNS,
        variables: VARIABLES,
        rows: ROWS,
        statuses: STATUSES,
        notes_title: "How to use",
        notes: NOTES
      }
    end

    # The example table, drawn from column B (column A is the margin; a narrow
    # gutter, C, follows the item column). key names a
    # column in formulas; kind picks the number format and alignment; section is
    # the head section (0-2) the column sits under. The first column is the row's
    # item, which the freeze keeps in view.
    COLUMNS = [
      { key: "item", section: 0, head: "[Item]", width: 32, kind: "item" },
      { key: "category", section: 0, head: "[Category]", width: 16, kind: "text" },
      { key: "owner", section: 0, head: "[Owner]", width: 16, kind: "text" },
      { key: "date", section: 1, head: "[Date]", width: 14, kind: "date" },
      { key: "amount", section: 1, head: "[Amount]", width: 14, kind: "money" },
      { key: "status", section: 1, head: "[Status]", width: 13, kind: "status" },
      { key: "rate", section: 2, head: "[Rate]", width: 10, kind: "percent" },
      { key: "applied", section: 2, head: "[Amount × Rate]", width: 17, kind: "formula",
        formula: '=IF({col:amount}{r}="","",{col:amount}{r}*IF({col:rate}{r}="",{var:Default rate},{col:rate}{r}))' },
      { key: "notes", section: 2, head: "[Notes]", width: 40, kind: "text" }
    ].freeze

    # Label (row 4) over value (row 5). The headline sits in column B, under the
    # title and the Last Updated line; the others run from column D (C is the gutter), under the
    # title and beside the Last Updated line. A column or variable may carry its
    # own number format (format: '"$"#,##0' for whole dollars), and a column its
    # own dropdown (choices: [...]). A variable may carry emphasis: true, the sheet's headline number,
    # drawn larger in the title colour (a copy of the template sets it, such as a
    # card roster's credit limit). In a value or a formula: {r} is the row, {first}/{last} the table's
    # first and last data row, {col:key} a column's letter and {var:Label} that
    # variable's cell, made absolute.
    # The first is the sheet's headline number (emphasis: true): large, in the
    # title colour, in whole dollars, as McRitchie Industries Cards shows its
    # total credit limit.
    VARIABLES = [
      { label: "Total amount", value: "=SUM({col:amount}{first}:{col:amount}{last})", kind: "money", format: '"$"#,##0',
        emphasis: true },
      { label: "Default rate", value: 0.05, kind: "percent" }
    ].freeze

    # The formula column reads each row's amount × its rate, or the Default rate
    # variable when the row leaves its rate blank.
    ROWS = [
      ["[Example item one]", "[Category A]", "[Name]", "2026-01-05", 1250.0, "Active", 0.05, nil, "[A short note]"],
      ["[Example item two]", "[Category B]", "[Name]", "2026-01-12", 480.5, "Active", 0.02, nil, ""],
      ["[Example item three]", "[Category A]", "[Name]", "2026-01-19", 3200.0, "Paused", nil, nil, "[A blank rate uses the Default rate]"],
      ["[Example item four]", "[Category C]", "[Name]", "2026-01-26", 75.25, "Closed", 0.1, nil, ""]
    ].freeze

    STATUSES = %w[Active Paused Closed].freeze

    NOTES = [
      "How to use this template",
      "Make your own: File, then Make a copy. Replace every [bracketed] word; keep the layout.",
      "No merged cells. A section label sits in the first cell of its section; the other cells share its colour. " \
      "This keeps every column free to move, sort and filter.",
      "Row 1 and column A are margins; A2 holds the brand icon and row 2 the title. The freeze holds rows 1-8 and columns A-B. " \
      "Keep the row's item (its name) in column B, so you always see which row you are on.",
      "Add a column: insert it inside a section and copy the head cells' format from a neighbour. " \
      "Add a row: insert it inside the table, so totals and dropdowns cover it.",
      "Variables sit under the title, label over value. Formulas point at them with absolute references ($D$5), " \
      "so a value changes in one place.",
      "Head colours come from the brand palette. Both head rows are dark enough for white text; " \
      "keep it that way if you recolour a section."
    ].freeze

    # --- colour maths (WCAG 2 relative luminance) ---

    def self.contrast_with_white(hex) = 1.05 / (luminance(hex) + 0.05)

    def self.luminance(hex)
      r, g, b = rgb(hex).map do |c|
        c /= 255.0
        c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
      end
      (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    end

    # The lower head's colour: the brand colour as it is when white text reads on
    # it; else the lightest step toward black that reaches LOW_TARGET, so the hue
    # survives. A near-black colour steps toward white to LOW_CEILING instead.
    def self.legible(hex)
      contrast = contrast_with_white(hex)
      return lighten_to(hex, LOW_CEILING) if contrast > LOW_CEILING
      return hex.upcase if contrast >= LOW_TARGET

      (1..100).each do |step|
        shade = mix(hex, "#000000", step / 100.0)
        return shade if contrast_with_white(shade) >= LOW_TARGET
      end
      "#000000"
    end

    def self.lighten_to(hex, ceiling)
      (1..100).map { |step| mix(hex, "#FFFFFF", step / 100.0) }.reverse
              .find { |shade| contrast_with_white(shade) >= ceiling } || hex.upcase
    end

    def self.mix(hex, other, t)
      a = rgb(hex)
      b = rgb(other)
      "#" + a.zip(b).map { |x, y| format("%02X", (x + ((y - x) * t)).round) }.join
    end

    def self.rgb(hex) = hex.delete("#").scan(/../).map { |c| c.to_i(16) }

    private

    def section_swatches
      named = Array(@spec.sheet[:sections])
      return named.map { |ref| swatch(ref) } if named.any?

      first_two = %i[primary accent].map { |k| swatch(k) }
      third = @spec.palette.find do |s|
        keys = Array(s[:key]).map(&:to_sym)
        !first_two.include?(s) && !keys.intersect?(SHADE_KEYS) && self.class.contrast_with_white(s[:hex]) >= MIN_CONTRAST
      end
      first_two + [third || swatch(:dark)]
    end

    # A swatch by its name ("Gunmetal") or its palette key (primary).
    def swatch(ref)
      @spec.palette.find { |s| s[:name].to_s.casecmp?(ref.to_s) } ||
        @spec.palette.find { |s| Array(s[:key]).map(&:to_sym).include?(ref.to_sym) } ||
        raise(Error, "sheet.sections: no swatch or key named #{ref.inspect}")
    end
  end
end
