# frozen_string_literal: true

module Books
  # config/books.yml, read once and checked: the chart of accounts, and each
  # entity's Drive, bank accounts and categorization rules. A rule naming a
  # category that is not in the chart raises at load, so a typo cannot quietly
  # leave lines unclassified.
  class Config
    PATH = Rails.root.join("config/books.yml")
    KINDS = %w[income expense contribution distribution transfer].freeze

    Error = Class.new(StandardError)

    Category = Struct.new(:key, :label, :kind, keyword_init: true)
    Account = Struct.new(:key, :bank, :product, :last4, :opened_on, keyword_init: true) do
      # "Money market ···9501": how the ledger and the balance sheet name it.
      def label = "#{key.to_s.humanize} ···#{last4}"
    end

    Rule = Struct.new(:name, :pattern, :sign, :category, :purpose, keyword_init: true) do
      def match?(description, amount_cents)
        return false if sign == "in" && amount_cents.negative?
        return false if sign == "out" && amount_cents.positive?

        pattern.match?(Config.squeeze(description))
      end
    end

    Entity = Struct.new(:key, :name, :drive_subject, :drive_root, :accounts, :rules, keyword_init: true) do
      def account(key) = accounts.fetch(key.to_s) { raise Error, "#{self.key} has no account #{key.inspect}" }

      def account_for_last4(last4) = accounts.values.find { |a| a.last4 == last4.to_s }
    end

    class << self
      def load(path = PATH) = new(YAML.safe_load_file(path, permitted_classes: [ Date ], aliases: false))

      def current = @current ||= load

      def reset! = @current = nil

      # The form rules match against: upper case, every space gone, because
      # statement text drops spaces unpredictably ("SERVICEFEE").
      def squeeze(text) = text.to_s.upcase.gsub(/\s+/, "")
    end

    attr_reader :categories

    def initialize(data)
      @categories = (data["categories"] || {}).to_h do |key, c|
        raise Error, "category #{key}: kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(c["kind"])

        [ key.to_s, Category.new(key: key.to_s, label: c.fetch("label"), kind: c["kind"]) ]
      end
      @entities = (data["entities"] || {}).to_h { |key, e| [ key.to_s, build_entity(key.to_s, e) ] }
    end

    def entity(key) = @entities.fetch(key.to_s) { raise Error, "no entity #{key.inspect} in config/books.yml (have: #{@entities.keys.join(', ')})" }

    def entities = @entities.values

    def category(key) = @categories.fetch(key.to_s) { raise Error, "no category #{key.inspect} in config/books.yml" }

    def categories_of(kind) = @categories.values.select { |c| c.kind == kind }

    private

    def build_entity(key, e)
      accounts = (e["accounts"] || {}).to_h do |akey, a|
        [ akey.to_s, Account.new(key: akey.to_s, bank: a.fetch("bank"), product: a["product"],
                                 last4: a.fetch("last4").to_s, opened_on: a.fetch("opened_on")) ]
      end
      rules = Array(e["rules"]).map do |r|
        category(r["category"]) if r["category"]
        raise Error, "rule #{r['name']}: sign must be in or out" if r["sign"] && !%w[in out].include?(r["sign"])

        Rule.new(name: r.fetch("name"), pattern: Regexp.new(r.fetch("match"), Regexp::IGNORECASE),
                 sign: r["sign"], category: r["category"], purpose: r["purpose"])
      end
      Entity.new(key: key, name: e.fetch("name"), drive_subject: e.fetch("drive_subject"),
                 drive_root: e.fetch("drive_root"), accounts: accounts, rules: rules)
    end
  end
end
