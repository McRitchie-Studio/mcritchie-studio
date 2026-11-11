# frozen_string_literal: true

require "yaml"
require "json"

module MarketingKit
  # One branded Google Sheet as data: which brand (a kit spec), what tables, and
  # where it lives in Drive. The Sheet Template's drawer turns a recipe into an
  # .xlsx; SheetPublisher puts it in Drive. A recipe that holds private rows (a
  # card roster) lives in Drive beside its sheet, never in this public repo.
  #
  #   kit: ../ms-kit/kit.yml            # the brand: a marketing-kit spec, relative to the recipe
  #   title: McRitchie Studio Cards
  #   sections: [Card, Terms, Rewards]  # the three head labels (colours come from the kit)
  #   columns: [{ key:, head:, kind:, width:, section:, format:, choices:, age_bands:, target: }]
  #   variables: [{ label:, value:, kind:, format:, emphasis: }]
  #   rows: rows.json                   # a JSON file of row arrays beside the recipe, or an inline list
  #   tabs: [{ sheet_title:, title:, sections:, columns:, variables:, rows: }]   # optional: several tables
  #   notes: ["How to use", "..."]
  #   drive: { subject: team@mcritchie.studio, folder: McRitchie Studio Records, name: McRitchie Studio Cards }
  #
  # Column kinds beyond the template's: `stamp` (a tick-box column; its `target`
  # names the date column it stamps, and SheetPublisher makes real checkboxes in
  # place) and `age_bands` on a date column ({ months: [4, 10, 16], fresh: ["💳"] }).
  class SheetRecipe
    TABLE_KEYS = %i[sheet_title title sections columns variables rows statuses].freeze
    KINDS = %w[item text date money percent status formula archive stamp].freeze

    attr_reader :path, :data

    def self.load(path)
      path = File.expand_path(path)
      raise Error, "no sheet recipe at #{path}" unless File.file?(path)

      data = YAML.safe_load_file(path, permitted_classes: [Date], aliases: false)
      raise Error, "#{path}: a recipe must be a YAML mapping" unless data.is_a?(Hash)

      new(data, root: File.dirname(path), path: path)
    end

    def initialize(data, root:, path: nil)
      @data = deep_symbolize(data)
      @root = root
      @path = path
      validate!
    end

    def spec = @spec ||= Spec.load(File.expand_path(data.fetch(:kit), @root))
    def drive = data.fetch(:drive)
    def name = drive[:name] || data.fetch(:title)

    # The drawer's payload: the template's brand and defaults, then the recipe.
    def payload
      base = SheetTemplate.new(spec).payload
      tables = data[:tabs] ? data[:tabs].map { |t| table(t, base) } : nil
      top = table(data.slice(*TABLE_KEYS), base)
      top.merge(tabs: tables, notes_title: data[:notes_title] || base[:notes_title], notes: Array(data[:notes].presence || base[:notes]))
         .compact
    end

    # Every stamp column, for the publisher to turn into checkboxes in place:
    # [{ tab:, column: (0-based sheet column), target: }].
    def stamps
      tables = data[:tabs] || [data]
      tables.flat_map do |t|
        Array(t[:columns]).each_with_index.filter_map do |c, i|
          next unless c[:kind] == "stamp"

          { tab: t[:sheet_title] || data[:sheet_title] || "Sheet", column: self.class.sheet_column(i) - 1, target: c[:target] }
        end
      end
    end

    # The drawer's layout: column A is the margin, the item column is B, a gutter
    # is C, and table column i > 0 sits one further right (1-based).
    def self.sheet_column(i) = 2 + i + (i.positive? ? 1 : 0)

    private

    def table(t, base)
      sections = Array(t[:sections]).presence
      out = {
        sheet_title: t[:sheet_title], title: t[:title],
        sections: sections && base[:sections].zip(sections).map { |s, label| s.merge(label: label) },
        columns: t[:columns], variables: t[:variables], rows: rows(t[:rows]), statuses: t[:statuses]
      }.compact
      base.merge(out).except(:tabs)
    end

    def rows(source)
      case source
      when nil then nil
      when String then JSON.parse(File.read(File.expand_path(source, @root)))
      else source
      end
    end

    def validate!
      raise Error, "#{label}: kit is required (a marketing-kit spec for the brand)" if data[:kit].blank?
      raise Error, "#{label}: title is required" if data[:title].blank? && data[:tabs].blank?
      raise Error, "#{label}: drive.subject and drive.folder are required" unless data[:drive].is_a?(Hash) && drive[:subject].present? && drive[:folder].present?

      (data[:tabs] || [data]).each { |t| validate_table!(t) }
    end

    def validate_table!(t)
      cols = Array(t[:columns])
      return if cols.empty? # the template's own example table

      raise Error, "#{label}: the first column must be the item (kind: item)" unless cols.first[:kind] == "item"

      keys = cols.map { |c| c[:key].to_s }
      raise Error, "#{label}: column keys must be unique" if keys.uniq.size != keys.size

      cols.each do |c|
        raise Error, "#{label}: column #{c[:key]} has unknown kind #{c[:kind].inspect}" unless KINDS.include?(c[:kind].to_s)
        if c[:kind] == "stamp" && !cols.any? { |o| o[:head] == c[:target] }
          raise Error, "#{label}: stamp column #{c[:key]} targets #{c[:target].inspect}, which is no column's head"
        end
        bands = c[:age_bands]
        next unless bands
        raise Error, "#{label}: age_bands needs three months, freshest first" unless Array(bands[:months]).size == 3 && bands[:months] == bands[:months].sort
      end
    end

    def label = path ? File.basename(path) : "sheet recipe"

    def deep_symbolize(v)
      case v
      when Hash then v.to_h { |k, x| [k.to_sym, deep_symbolize(x)] }
      when Array then v.map { |x| deep_symbolize(x) }
      else v
      end
    end
  end
end
