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
end
