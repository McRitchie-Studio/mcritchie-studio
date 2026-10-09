# The navigation registry (config/navigation.yml): every page a nav links and
# every page a visitor may open, read by the link sidebar (LinkTreeHelper), the
# section sub-navs (components/_sub_nav) and the admin wall (AdminWall).
#
# A registry that does not validate does not load: an audience other than
# `public` or `admin`, a placement naming an unknown page, or one controller
# action declared twice raises Navigation::Invalid. Nothing here reads the route
# table, because the wall builds its list while the app is still loading;
# test/models/navigation_test.rb holds each page equal to its route.
class Navigation
  class Invalid < StandardError; end

  PATH = Rails.root.join("config/navigation.yml")
  AUDIENCES = %w[public admin].freeze
  GROUPS = %w[admin general].freeze
  STYLES = %w[links buttons chips].freeze

  # `key` is the page's route name, so `tasks` links tasks_path.
  Page = Struct.new(:key, :controller, :action, :audience, :args, :label, :emoji, :hover_emoji, :desc,
                    keyword_init: true) do
    def public? = audience == "public"
    def action_id = "#{controller}##{action}"

    # The page's path, from the route helpers of `view` (a view or helper context).
    def path(view) = view.send(:"#{key}_path", *args)
  end

  Section = Struct.new(:title, :group, :pages, keyword_init: true)

  Item = Struct.new(:page, :label, :icon, :back, :only, :except, :hide_when_current, :narrow_only_on,
                    :badges, :count, :test_id, keyword_init: true) do
    def text = label || page.label

    # Whether the item belongs on the page keyed `current`.
    def shown_on?(current)
      return false if only && !only.include?(current)
      return false if except&.include?(current)

      !(hide_when_current && page.key == current)
    end
  end

  SubNav = Struct.new(:key, :style, :label, :items, keyword_init: true)

  class << self
    delegate :pages, :page, :sidebar, :sub_nav, :sub_navs, :public_actions, :placed_keys, to: :registry

    def registry
      @registry ||= new(YAML.safe_load_file(PATH))
    end
  end

  attr_reader :pages, :sub_navs

  def initialize(data)
    data = data.to_h
    @pages = build_pages(data["pages"])
    @sections = build_sections(data["sidebar"])
    @sub_navs = build_sub_navs(data["sub_navs"])
  end

  def page(key)
    @pages.fetch(key.to_s) { raise Invalid, "navigation names no page #{key.inspect}" }
  end

  # The sidebar sections of one group, in registry order.
  def sidebar(group)
    @sections.select { |section| section.group == group.to_s }
  end

  def sub_nav(key)
    @sub_navs.fetch(key.to_s) { raise Invalid, "navigation names no sub-nav #{key.inspect}" }
  end

  # controller_path => actions, for every page whose audience is public. The
  # admin wall's public page list.
  def public_actions
    @pages.values.select(&:public?).group_by(&:controller).transform_values { |pages| pages.map(&:action) }
  end

  # Keys of the pages a sidebar section or a sub-nav links.
  def placed_keys
    (@sections.flat_map(&:pages) + @sub_navs.values.flat_map { |nav| nav.items.map(&:page) }).map(&:key).uniq
  end

  # Pages whose declared controller#action is not what their route serves, as
  # messages. `named_routes` is Rails.application.routes.named_routes.
  def route_mismatches(named_routes)
    @pages.values.filter_map do |page|
      route = named_routes[page.key]
      next "#{page.key}: no route is named #{page.key}" unless route

      served = "#{route.defaults[:controller]}##{route.defaults[:action]}"
      "#{page.key}: declared #{page.action_id}, the route serves #{served}" unless served == page.action_id
    end
  end

  private

  def build_pages(raw)
    pages = raw.to_h.to_h do |key, attrs|
      attrs = attrs.to_h
      controller, action = attrs["page"].to_s.split("#", 2)
      raise Invalid, "#{key}: page must be controller#action" if controller.blank? || action.blank?
      unless AUDIENCES.include?(attrs["audience"])
        raise Invalid, "#{key}: audience must be public or admin, got #{attrs['audience'].inspect}"
      end
      raise Invalid, "#{key}: a label is required" if attrs["label"].blank?

      [key.to_s, Page.new(key: key.to_s, controller: controller, action: action, audience: attrs["audience"],
                          args: Array(attrs["args"]).freeze, label: attrs["label"].to_s, emoji: attrs["emoji"],
                          hover_emoji: attrs["hover_emoji"], desc: attrs["desc"]).freeze]
    end
    twice = pages.values.group_by(&:action_id).select { |_, list| list.size > 1 }
    raise Invalid, "declared twice: #{twice.keys.join(', ')}" if twice.any?

    pages.freeze
  end

  def build_sections(raw)
    Array(raw).map do |attrs|
      raise Invalid, "sidebar section #{attrs['title'].inspect}: group must be admin or general" unless GROUPS.include?(attrs["group"])

      Section.new(title: attrs["title"].to_s, group: attrs["group"],
                  pages: Array(attrs["pages"]).map { |key| page(key) }.freeze).freeze
    end.freeze
  end

  def build_sub_navs(raw)
    raw.to_h.to_h do |key, attrs|
      raise Invalid, "sub-nav #{key}: style must be one of #{STYLES.join(', ')}" unless STYLES.include?(attrs["style"])

      items = Array(attrs["items"]).map { |item| build_item(item) }.freeze
      [key.to_s, SubNav.new(key: key.to_s, style: attrs["style"], label: attrs["label"].to_s, items: items).freeze]
    end.freeze
  end

  def build_item(attrs)
    # Every page key an item names must exist, the conditions included: a typo
    # there would silently show or hide a link.
    conditions = %w[only except narrow_only_on].to_h { |name| [name, attrs[name]&.map { |key| page(key).key }] }
    Item.new(page: page(attrs["page"]), label: attrs["label"], icon: attrs["icon"] == true, back: attrs["back"] == true,
             only: conditions["only"], except: conditions["except"], narrow_only_on: conditions["narrow_only_on"],
             hide_when_current: attrs["hide_when_current"] == true, badges: Array(attrs["badges"]).map(&:to_s).freeze,
             count: attrs["count"]&.transform_keys(&:to_sym), test_id: attrs["test_id"]).freeze
  end
end
