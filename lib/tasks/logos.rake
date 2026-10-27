# frozen_string_literal: true

namespace :logos do
  desc "Write every Navbar Logo example and guide drawing for a brand as SVG: logos:navbar[industries] (optional second arg: output dir, default tmp/logos/<brand>)"
  task :navbar, [:brand, :dir] => :environment do |_task, args|
    abort "usage: bin/rails 'logos:navbar[<brand>]' — brands: #{Logos::NavbarLogo.brands.join(', ')}" if args[:brand].blank?

    logo = begin
      Logos::NavbarLogo.new(args[:brand])
    rescue Logos::NavbarLogo::Error => e
      abort "logos:navbar: #{e.message}"
    end
    dir = Pathname(args[:dir].presence || Rails.root.join("tmp/logos", logo.brand))
    FileUtils.mkdir_p(dir)
    logo.examples.each do |example|
      path = dir.join("#{example[:key]}.svg")
      File.write(path, example[:svg])
      puts path
    end
  end

  # FROM= (task brand-kit-applied-status) installs the kit a kit.json names instead of this database's: production's
  # kit, read with `BrandKitInstall.manifest_for` there (the brand-kit-rollout SOP), so a desk installs the exact kit
  # and saved_at production holds without copying the row.
  desc "Install a brand's saved kit into an app: BRAND=studio [DEST=public/brand] [FROM=<kit.json>] writes every kit file, byte-equal to /logos/<brand>/kit/<file>, plus kit.json"
  task install: :environment do
    brand = ENV["BRAND"].to_s
    unless Logos::NavbarLogo.brands.include?(brand)
      abort "usage: bin/rails logos:install BRAND=<brand> [DEST=<dir>] [FROM=<kit.json>] — brands: #{Logos::NavbarLogo.brands.join(', ')}"
    end

    kit = if ENV["FROM"].present?
            begin
              BrandKitInstall.kit_from_manifest(File.read(ENV["FROM"]), brand:)
            rescue Errno::ENOENT, JSON::ParserError, ArgumentError => e
              abort "logos:install: FROM=#{ENV['FROM']}: #{e.message}"
            end
          else
            BrandKit.for(brand)
          end
    warn "logos:install: #{brand} has no saved kit in this database (#{Rails.env}); writing the brand's defaults" unless kit.persisted? || ENV["FROM"].present?
    dest = ENV["DEST"].presence ? Pathname(ENV["DEST"]).expand_path : BrandKitInstall.default_dest
    result = BrandKitInstall.new(kit, dest:).call
    result.written.each { |name| puts "wrote     #{dest.join(name)}" }
    result.unchanged.each { |name| puts "unchanged #{dest.join(name)}" }
    result.refused.each { |name, why| warn "refused   #{name}: #{why}" }
  end

  # Task brand-kit-applied-status: the brand-kit-rollout SOP's last step, run on the hub's PRODUCTION database once the
  # app's live /brand/kit.json carries the kit's saved_at. SAVED_AT is that saved_at (default: the kit's own).
  desc "Record that a brand's kit was applied to an app: BRAND=turf APP=turf-monster [AT=<time>] [BY=<who>] [SAVED_AT=<kit.json saved_at>]"
  task applied: :environment do
    brand = ENV["BRAND"].to_s
    app = ENV["APP"].to_s
    usage = "usage: bin/rails logos:applied BRAND=<brand> APP=<app slug> [AT=<time>] [BY=<who>] [SAVED_AT=<time>] — brands: #{Logos::NavbarLogo.brands.join(', ')}"
    abort usage unless Logos::NavbarLogo.brands.include?(brand) && app.present?
    abort "logos:applied: no app #{app.inspect} in this database (#{Rails.env})" unless App.exists?(slug: app)

    time = lambda do |name|
      value = ENV[name].presence or next
      Time.zone.parse(value) || abort("logos:applied: #{name}=#{value.inspect} is not a time")
    rescue ArgumentError
      abort "logos:applied: #{name}=#{value.inspect} is not a time"
    end
    by = ENV["BY"].presence || ENV["USER"].presence || "unknown"
    link = BrandKitApp.record_applied!(brand:, app_slug: app, by:, at: time.call("AT"), saved_at: time.call("SAVED_AT"))
    puts "#{brand} → #{app}: #{link.status_label} (used #{link.used_at.utc.iso8601} by #{link.used_by}, " \
         "kit saved #{link.applied_saved_at&.utc&.iso8601 || 'never'})"
  end

  # Task stacked-rule-of-three: an icon's box is its ink (Logos::IconInk), and NavbarLogo refuses one that is not.
  desc "Trim every icon in the icon data (lib/logos/data/brand_icons*.json) to its ink, then re-derive Commercial Welding v2's helmet"
  task trim_icons: :environment do
    files = Logos::NavbarLogo::ICON_FILES.map { |file| File.join(Logos::NavbarLogo::ROOT, "lib/logos/data", file) } - [Logos::WeldingV2::FILE]
    files.each do |path|
      json, changed = Logos::IconInk.trim_data(File.read(path))
      File.write(path, json) if changed.any?
      puts "#{changed.any? ? 'trimmed  ' : 'unchanged'} #{File.basename(path)}#{" (#{changed.join(', ')})" if changed.any?}"
    end
    Logos::NavbarLogo.instance_variable_set(:@icons, nil)   # read the trimmed v1 helmets back before deriving v2's
    File.write(Logos::WeldingV2::FILE, Logos::WeldingV2.json)
    puts "derived   #{File.basename(Logos::WeldingV2::FILE)}"
  end

  # Task footer-stacked-logo: the favicon draws the small-size mark (Logos::SmallMark), the icon without the specks
  # a 16-32 px tab cannot show. Its colour is the installed kit's dark-page icon, so a kit colour change carries over.
  desc "Write the favicon's small-size mark: BRAND=studio [ICON=studio] [OUT=public/favicon-mark.svg]; then rasterize it with script/brand_png.cjs"
  task favicon_mark: :environment do
    brand = ENV["BRAND"].presence || "studio"
    key = ENV["ICON"].presence || brand
    icon = Logos::NavbarLogo.icons[key] or abort "logos:favicon_mark: no icon #{key.inspect} in the icon data"
    kit_icon = Rails.public_path.join("brand/icon-dark.svg")
    fill = File.exist?(kit_icon) && File.read(kit_icon)[/ fill="(#\h{3,8})"/, 1]
    abort "logos:favicon_mark: no fill colour in #{kit_icon}; run logos:install BRAND=#{brand} first" unless fill
    out = Pathname(ENV["OUT"].presence || Rails.public_path.join("favicon-mark.svg"))
    File.write(out, Logos::SmallMark.svg(Logos::SmallMark.derive(icon), fill:))
    puts "wrote #{out}"
    puts "then: node script/brand_png.cjs #{out.relative_path_from(Rails.root)} public/favicon.png 256"
  end

  desc "Write Commercial Welding v2's helmet (welding_v2, welding_v2_mono), derived from v1's, to lib/logos/data/brand_icons_welding_v2.json"
  task welding_v2: :environment do
    File.write(Logos::WeldingV2::FILE, Logos::WeldingV2.json)
    puts Logos::WeldingV2::FILE
  end
end
