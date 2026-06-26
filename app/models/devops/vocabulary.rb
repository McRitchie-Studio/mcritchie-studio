# frozen_string_literal: true

module Devops
  # Reads config/devops_vocabulary.yml — the single source of truth for the DevOps
  # SOP vocabulary (owner definition, primary/light roles, node types, the four
  # accountability lanes). ApplicationHelper renders /stages/sop from this; renaming
  # a term in the YAML flows to the UI in one edit. Reloads per request in
  # development so YAML edits show immediately; memoized otherwise.
  module Vocabulary
    PATH = Rails.root.join("config", "devops_vocabulary.yml")

    class << self
      def data
        return load_yaml if Rails.env.development?

        @data ||= load_yaml
      end

      def owner_definition = data[:owner_definition]
      def reviewer_roles   = data[:reviewer_roles]
      def node_types       = data[:node_types]
      def lanes            = data[:lanes]

      # The visual treatment for a node type (falls back to :stage for an unknown).
      def node_type(type)
        node_types.fetch(type.to_sym, node_types[:stage])
      end

      def reload!
        @data = nil
        data
      end

      private

      def load_yaml
        raw = YAML.safe_load_file(PATH, permitted_classes: [], aliases: false)
        sym = raw.deep_symbolize_keys
        # Symbolize each step's :type VALUE (deep_symbolize_keys only touches keys),
        # so view comparisons like `step[:type] == :pulse` hold.
        sym[:lanes].each { |lane| lane[:steps].each { |s| s[:type] = s[:type].to_sym if s[:type] } }
        sym.freeze
      end
    end
  end
end
