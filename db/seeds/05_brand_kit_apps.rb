# Which apps take which brand kit (BrandKitApp; task brand-kit-applied-status): the same links the
# CreateBrandKitApps migration seeded on deployed databases, for a database built from schema.rb. Idempotent;
# an app with no row is skipped. Nothing is stamped applied: `bin/rails logos:applied` records that
# (docs/agents/agents/alex/sops/brand-kit-rollout.md).
BrandKitApp::SEED_LINKS.each do |brand, app_slug|
  next puts("BrandKitApp: skipped #{brand} → #{app_slug} (no app row)") unless App.exists?(slug: app_slug)

  BrandKitApp.find_or_create_by!(brand:, app_slug:)
end
