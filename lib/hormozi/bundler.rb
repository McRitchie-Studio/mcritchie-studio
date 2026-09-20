# frozen_string_literal: true

require "json"

module Hormozi
  # Groups everything the extraction wave pulled out of the transcripts into one
  # bundle per idea, ranked by how often he says it.
  #
  # WHY RANK BY REPETITION. The alternative is to decide from memory which of
  # his frameworks matter, which reproduces what the model already believed
  # about him and learns nothing from the corpus. Counting distinct SOURCES —
  # not items — makes the corpus itself say which ideas are doctrine and which
  # were said once on a podcast: an idea he returns to across 40 videos outranks
  # one he mentioned twice in the same hour.
  module Bundler
    KINDS = %w[framework play diagnostic case voice benchmark belief].freeze

    # An item is unusable without these; a bundle built from half-formed items
    # produces a card that cites nothing.
    REQUIRED_FIELDS = %w[kind name claim source_id].freeze

    Bundle = Struct.new(:kind, :name, :slug, :items, :sources, keyword_init: true) do
      def source_count = sources.length
      def item_count = items.length
    end

    # Reads every extraction file and returns bundles sorted by distinct source
    # count, descending — doctrine first.
    def self.build(paths)
      grouped = Hash.new { |hash, key| hash[key] = [] }

      paths.each do |path|
        payload = parse(path)
        next if payload.nil?

        Array(payload["items"]).each do |item|
          next unless usable?(item)

          grouped[[ item["kind"], normalize(item["name"]) ]] << item
        end
      end

      grouped.map { |(kind, slug), items| bundle_for(kind, slug, items) }
             .sort_by { |bundle| [ -bundle.source_count, -bundle.item_count, bundle.slug ] }
    end

    def self.bundle_for(kind, slug, items)
      Bundle.new(
        kind: kind,
        name: most_common_name(items),
        slug: slug,
        items: items,
        sources: items.map { |item| item["source_id"] }.compact.uniq
      )
    end

    # Extraction runs across many agents, so the same idea comes back spelled a
    # dozen ways ("the value equation", "Value Equation:", "value-equation").
    # Bundling on the raw name would scatter one framework across a dozen cards.
    def self.normalize(name)
      name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
    end

    # The bundle answers to the spelling most agents chose, not to whichever
    # file happened to be read first.
    def self.most_common_name(items)
      items.map { |item| item["name"].to_s.strip }
           .reject(&:empty?)
           .tally
           .max_by { |name, count| [ count, -name.length ] }
           &.first
    end

    def self.usable?(item)
      return false unless item.is_a?(Hash)
      return false unless REQUIRED_FIELDS.all? { |field| item[field].to_s.strip != "" }

      KINDS.include?(item["kind"])
    end

    # A single malformed batch file must not take the whole synthesis down —
    # the wave is dozens of agents writing JSON, and one of them will truncate.
    def self.parse(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT
      warn "skipping unreadable extraction file: #{path}"
      nil
    end
  end
end
