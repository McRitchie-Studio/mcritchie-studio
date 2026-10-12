# The model was MusicVideo (table music_videos) until 2026-10-12; it is Video now
# (app/models/video.rb). This alias stays so anything serialized under the old
# name still loads: a GlobalID ("gid://.../MusicVideo/1"), an ActiveJob argument,
# a cache entry or a polymorphic *_type string written by a release older than
# the rename. Nothing in the app names it; test/models/video_test.rb pins it.
MusicVideo = Video
