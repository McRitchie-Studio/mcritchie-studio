# frozen_string_literal: true

# Regenerates the Studio Sheets add-on's brand table from the kit specs:
#
#   bin/rails runner script/marketing_kit/addon_brands.rb <kit.yml>...
#
# Pass every brand's spec (MI, MS, CW, TM) each time: the table is rewritten
# whole. It writes addons/studio-sheets/src/Brands.js; commit the result.
paths = ARGV.reject { |a| a.start_with?("-") }
abort "usage: bin/rails runner script/marketing_kit/addon_brands.rb <kit.yml>..." if paths.empty?

specs = paths.map { |p| MarketingKit::Spec.load(p) }
out = Rails.root.join(MarketingKit::AddonBrands::OUT)
File.write(out, MarketingKit::AddonBrands.render(specs))
puts "wrote #{out.relative_path_from(Rails.root)} (#{specs.map(&:short).sort.join(', ')})"
