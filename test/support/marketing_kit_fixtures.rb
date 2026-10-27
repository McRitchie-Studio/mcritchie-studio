# A marketing kit on disk for the MarketingKit tests: the worked example spec
# (script/marketing_kit/kit.example.yml) copied into a temp folder with stand-in
# logo, photo and doc files beside it, so the spec loads as a real brand's would.
require "tmpdir"
require "fileutils"
require "yaml"

module MarketingKitFixtures
  EXAMPLE = Rails.root.join("script/marketing_kit/kit.example.yml").to_s
  PNGS = %w[full_light full_dark horizontal_light horizontal_dark icon_light icon_dark icon_512].freeze

  # Yields the spec path; `edit` receives the parsed YAML hash to change first.
  def with_kit(edit: nil, skip: [])
    Dir.mktmpdir("marketing-kit") do |dir|
      data = YAML.safe_load_file(EXAMPLE, permitted_classes: [Date])
      edit&.call(data)
      File.write(File.join(dir, "kit.yml"), data.to_yaml)
      PNGS.each { |n| stand_in(dir, "logos/png/#{n}.png", "png #{n}") unless skip.include?(n) }
      %w[full_light horizontal_dark].each { |n| stand_in(dir, "logos/svg/#{n}.svg", "<svg>#{n}</svg>") }
      Array(data.dig("photos", "items")).each { |p| stand_in(dir, "photos/#{p['file']}", "jpg #{p['file']}") }
      stand_in(dir, "docs/messaging.html", "<h1>Messaging</h1><p>Approved lines.</p>")
      yield File.join(dir, "kit.yml")
    end
  end

  def load_kit(**opts, &blk)
    with_kit(**opts) { |path| blk.call(MarketingKit::Spec.load(path)) }
  end

  private

  def stand_in(dir, rel, body)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end
end
