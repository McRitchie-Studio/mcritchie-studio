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

  desc "Install a brand's saved kit into an app: BRAND=studio [DEST=public/brand] writes every kit file, byte-equal to /logos/<brand>/kit/<file>, plus kit.json"
  task install: :environment do
    brand = ENV["BRAND"].to_s
    unless Logos::NavbarLogo.brands.include?(brand)
      abort "usage: bin/rails logos:install BRAND=<brand> [DEST=<dir>] — brands: #{Logos::NavbarLogo.brands.join(', ')}"
    end

    kit = BrandKit.for(brand)
    warn "logos:install: #{brand} has no saved kit in this database (#{Rails.env}); writing the brand's defaults" unless kit.persisted?
    dest = ENV["DEST"].presence ? Pathname(ENV["DEST"]).expand_path : BrandKitInstall.default_dest
    result = BrandKitInstall.new(kit, dest:).call
    result.written.each { |name| puts "wrote     #{dest.join(name)}" }
    result.unchanged.each { |name| puts "unchanged #{dest.join(name)}" }
    result.refused.each { |name, why| warn "refused   #{name}: #{why}" }
  end

  desc "Write Commercial Welding v2's helmet (welding_v2, welding_v2_mono), derived from v1's, to lib/logos/data/brand_icons_welding_v2.json"
  task welding_v2: :environment do
    File.write(Logos::WeldingV2::FILE, Logos::WeldingV2.json)
    puts Logos::WeldingV2::FILE
  end
end
