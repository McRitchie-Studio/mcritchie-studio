# frozen_string_literal: true

# The EOS accountability chart as data: config/accountability_chart.yml read into
# seats, with the shape checks the chart depends on. No table, no board.
#
# A seat has exactly one owner and about five roles; one owner may hold several
# seats. An owner is a soul from config/souls.yml (the roster Task::SOUL_ROSTER
# reads), a human named under `humans:`, or, for a `session` seat, the soul the
# orchestrating session wears. Plan: .agents/epics/accountability-chart.md.
#
#   chart = AccountabilityChart.load
#   chart.seat("operations").owner   # => "mason"
#   chart.children("operations")     # => the sub-seats under Ops
#   chart.errors                     # => [] when the shape holds
class AccountabilityChart
  PATH = Rails.root.join("config/accountability_chart.yml")
  SOULS_PATH = Rails.root.join("config/souls.yml")
  OWNER_KINDS = %w[soul human session].freeze
  MIN_ROLES = 3
  MAX_ROLES = 7

  Seat = Struct.new(:slug, :name, :parent, :owner, :owner_kind, :title, :group, :lights, :page, :roles,
                    keyword_init: true) do
    def human? = owner_kind == "human"
  end

  attr_reader :seats, :humans, :souls

  def self.load(path = PATH, souls_path: SOULS_PATH)
    data = YAML.safe_load_file(path)
    souls = YAML.safe_load_file(souls_path).fetch("souls").map { |s| s.fetch("slug") }
    new(data, souls: souls)
  end

  def initialize(data, souls:)
    @humans = data.fetch("humans", {}) || {}
    @souls = souls
    @seats = Array(data.fetch("seats")).map do |row|
      Seat.new(slug: row["slug"], name: row["name"], parent: row["parent"], owner: row["owner"],
               owner_kind: row["owner_kind"] || "soul", title: row["title"], group: row["group"],
               lights: Array(row["lights"]), page: row["page"], roles: Array(row["roles"]))
    end
  end

  def seat(slug) = seats.find { |s| s.slug == slug }
  def root = seats.find { |s| s.parent.nil? }
  def children(slug) = seats.select { |s| s.parent == slug }
  def seats_owned_by(owner) = seats.select { |s| s.owner == owner }

  # Who sits in a seat, as a person reads it: the human's name, else the soul slug.
  def owner_name(seat) = seat.human? ? humans.fetch(seat.owner) : seat.owner

  # Every way the chart breaks its own rules, as sentences; empty when it holds.
  def errors
    list = []
    slugs = seats.map(&:slug)
    slugs.tally.each { |slug, n| list << "seat #{slug.inspect} appears #{n} times" if n > 1 }
    roots = seats.select { |s| s.parent.nil? }
    list << "the chart needs exactly one top seat, found #{roots.map(&:slug).inspect}" unless roots.size == 1
    seats.each { |seat| list.concat(seat_errors(seat, slugs)) }
    seats.each { |seat| list << "seat #{seat.slug.inspect} never reaches the top seat (a parent loop)" if loops?(seat) }
    list
  end

  def valid? = errors.empty?

  private

  def loops?(start)
    seen = []
    current = start
    while current&.parent
      return true if seen.include?(current.slug)

      seen << current.slug
      current = seat(current.parent)
    end
    false
  end

  def seat_errors(seat, slugs)
    list = []
    label = "seat #{seat.slug.inspect}"
    list << "#{label} has no name" if seat.name.to_s.strip.empty?
    owner = seat.owner
    if !owner.is_a?(String) || owner.strip.empty?
      list << "#{label} needs exactly one owner, got #{owner.inspect}"
    elsif !OWNER_KINDS.include?(seat.owner_kind)
      list << "#{label} has unknown owner_kind #{seat.owner_kind.inspect}"
    elsif seat.human?
      list << "#{label} names human #{owner.inspect}, who is not under humans:" unless humans.key?(owner)
    elsif !souls.include?(owner)
      list << "#{label} is owned by #{owner.inspect}, which is not a soul in config/souls.yml"
    end
    seat.lights.each do |light|
      list << "#{label} names light #{light.inspect}, which is not a soul" unless souls.include?(light)
      list << "#{label} names its owner as a light" if light == owner
    end
    unless seat.parent.nil? || slugs.include?(seat.parent)
      list << "#{label} has parent #{seat.parent.inspect}, which is not a seat"
    end
    roles = seat.roles.map(&:to_s).reject { |r| r.strip.empty? }
    unless roles.size.between?(MIN_ROLES, MAX_ROLES) && roles.size == seat.roles.size
      list << "#{label} has #{roles.size} roles; a seat carries about five (#{MIN_ROLES}-#{MAX_ROLES})"
    end
    list
  end
end
