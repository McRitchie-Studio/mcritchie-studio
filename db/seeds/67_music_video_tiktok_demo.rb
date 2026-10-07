# The TikTok draft's demo (recast pipeline, piece 19): a synthetic 45 s video
# whose alt video 1 swaps Person 1 into a synthetic athlete in a Buffalo Bills
# look, with clip 1 holding a generated version (db/seeds/data/tiktok_draft_video.rb).
# Local only. No file is behind any row: run the hub with TIKTOK_DRAFT_STAND_IN=1
# and "Draft to TikTok" records an attempt, with its caption, without reaching
# R2 or TikTok.
return unless Rails.env.local?

require Rails.root.join("db/seeds/data/tiktok_draft_video.rb").to_s
video = TiktokDraftVideo.seed!
safe_puts "  TikTok draft video #{video.slug}: clip #{TiktokDraftVideo::CLIP} ready to draft"
