# bin/rails slug_keys:clean — the slug keys' post-deploy step (SlugKeyCleanup):
# clear the rows from before the keys that name a slug no parent holds, then
# validate each slug key still NOT VALID. Idempotent; prints counts only.
# Exits non-zero while a key stays NOT VALID (a NOT NULL column with dangling rows).
namespace :slug_keys do
  desc "Clean dangling slugs from before the slug foreign keys, then validate the keys (counts only)"
  task clean: :environment do
    report = SlugKeyCleanup.new.run
    lines = report.lines
    puts(lines.empty? ? "slug keys: nothing to clean, every key valid" : lines)
    abort "slug keys: #{report.left_not_valid.size} key(s) left NOT VALID" if report.left_not_valid.any?
  end
end
