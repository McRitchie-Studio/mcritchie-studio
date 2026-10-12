# The namespace was MusicVideos (app/services, lib) until 2026-10-12; it is Videos
# now. This alias stays so a queued job, a cache entry or a log line that names a
# MusicVideos:: class still resolves (MusicVideos::RunStitch is Videos::RunStitch).
# Nothing in the app names it; test/models/video_test.rb pins it.
MusicVideos = Videos
