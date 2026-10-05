# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/music_videos/chunk_tiler"
require_relative "../../../lib/music_videos/stitch_plan"

# [unit] The final stitch's plan, with no ffmpeg and no file: the inputs, the
# frame each chunk owns, where each crossfade starts and how long it runs, the
# normalisation target, the filter graph and the ffmpeg arguments. Everything
# is timed from the chunks' recorded windows, never from a file's length.
class MusicVideosStitchPlanTest < Minitest::Test
  Plan = MusicVideos::StitchPlan
  Tiler = MusicVideos::ChunkTiler

  def source(width: 1920, height: 804, rate: 24, audio: "aac")
    Plan::Source.new(path: "/in/source.mp4", width:, height:, frame_rate: Rational(rate), audio_codec: audio)
  end

  # One take per window, 1920x804 at 24 fps and exactly its window long unless told otherwise.
  def takes(windows, **overrides)
    windows.map do |w|
      o = overrides.fetch(w.ordinal, {})
      Plan::Take.new(ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms, path: "/in/take_#{w.ordinal}.mp4",
                     width: o.fetch(:width, 1920), height: o.fetch(:height, 804), frame_rate: Rational(o.fetch(:rate, 24)),
                     duration_ms: o.fetch(:duration_ms, w.end_ms - w.start_ms))
    end
  end

  def build(windows = Tiler.windows(72_000), source: self.source, **overrides)
    Plan.build(takes: takes(windows, **overrides), source:, output: "/out/stitched.mp4")
  end

  def frames(plan) = plan.inputs.map { |i| [i.ordinal, i.start_frame, i.end_frame] }

  def joins(plan) = plan.joins.map { |j| [j.ordinal, j.offset_frame, j.frames] }

  def test_each_chunk_owns_its_windows_frames_and_fades_across_the_overlap
    plan = build

    assert_equal [[1, 0, 600], [2, 480, 1080], [3, 960, 1560], [4, 1440, 1728]], frames(plan)
    assert_equal [[2, 480, 120], [3, 960, 120], [4, 1440, 120]], joins(plan)
    assert_equal 1728, plan.total_frames
    assert_equal 72_000, plan.duration_ms
    assert_empty plan.warnings
  end

  def test_offsets_come_from_the_windows_not_from_how_long_a_file_runs
    exact = build
    drifting = build(1 => { duration_ms: 25_042 }, 2 => { duration_ms: 24_400 }, 3 => { duration_ms: 31_000 })

    assert_equal frames(exact), frames(drifting)
    assert_equal joins(exact), joins(drifting)
    assert_equal exact.filter_graph, drifting.filter_graph
    assert_equal exact.total_frames, drifting.total_frames
  end

  def test_a_fractional_rate_rounds_each_window_on_its_own_so_nothing_accumulates
    plan = build(source: source(rate: Rational(24_000, 1001)), **(1..4).to_h { |n| [n, { rate: Rational(24_000, 1001) }] })

    # 20 s is 479.52 frames: each start is rounded from zero, not added to the last.
    assert_equal [[1, 0, 599], [2, 480, 1079], [3, 959, 1558], [4, 1439, 1726]], frames(plan)
    assert_equal [[2, 480, 119], [3, 959, 120], [4, 1439, 119]], joins(plan)
    assert_equal 1726, plan.total_frames
    assert_in_delta 72_000, plan.duration_ms, 1001.0 / 24 / 2, "within half a frame of the source's length"
    assert_includes plan.filter_graph, "xfade=transition=fade:duration=4.963292:offset=20.020000[x1]"
  end

  def test_the_filter_graph_normalises_each_take_then_chains_the_crossfades
    plan = build(Tiler.windows(65_000))

    chain = "setpts=PTS-STARTPTS,fps=24,setsar=1,format=yuv420p,tpad=stop_mode=clone:stop_duration=25.000000," \
            "trim=end_frame=600,setpts=PTS-STARTPTS"
    assert_equal ["[0:v:0]#{chain}[v0]", "[1:v:0]#{chain}[v1]", "[2:v:0]#{chain}[v2]",
                  "[v0][v1]xfade=transition=fade:duration=5.000000:offset=20.000000[x1]",
                  "[x1][v2]xfade=transition=fade:duration=5.000000:offset=40.000000[vout]"], plan.filter_graph.split(";")
  end

  def test_the_arguments_take_picture_from_the_takes_and_audio_from_the_source
    plan = build(Tiler.windows(65_000))

    assert_equal ["-y", "-v", "error", "-nostdin", "-an", "-i", "/in/take_1.mp4", "-an", "-i", "/in/take_2.mp4",
                  "-an", "-i", "/in/take_3.mp4", "-vn", "-i", "/in/source.mp4", "-filter_complex", plan.filter_graph,
                  "-map", "[vout]", "-map", "3:a:0", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                  "-pix_fmt", "yuv420p", "-c:a", "copy", "-t", "65.000000", "-movflags", "+faststart",
                  "/out/stitched.mp4"], plan.arguments
    assert_equal :copy, plan.audio
    # The source audio reaches the output through no filter: the fades cannot touch it.
    refute_includes plan.filter_graph, ":a"
  end

  def test_source_audio_that_is_not_aac_is_encoded_and_a_silent_source_maps_none
    encoded = build(source: source(audio: "opus"))
    assert_equal :encode, encoded.audio
    assert_equal %w[-c:a aac -b:a 192k], encoded.arguments[encoded.arguments.index("-c:a"), 4]

    silent = build(source: source(audio: nil))
    assert_equal :none, silent.audio
    refute_includes silent.arguments, "-vn"
    refute_includes silent.arguments, "-c:a"
    assert_equal ["[vout]"], silent.arguments.each_cons(2).filter_map { |flag, value| value if flag == "-map" }
    assert_includes silent.warnings, "the source has no audio: the stitch is silent"
  end

  def test_the_target_is_the_best_take_and_never_more_than_the_source
    # Every take came back smaller than the source: stitched at their size, no invented pixels.
    small = build(**(1..4).to_h { |n| [n, { width: 1484, height: 620 }] })
    assert_equal [1484, 620, Rational(24)], small.target.to_h.values
    assert_equal %i[exact exact exact exact], small.inputs.map(&:fit)
    refute_includes small.filter_graph, "scale="

    # A mixed set is brought up to its best member.
    mixed = build(2 => { width: 1484, height: 620 })
    assert_equal [1920, 804], [mixed.target.width, mixed.target.height]
    assert_equal %i[exact stretch exact exact], mixed.inputs.map(&:fit)
    assert_includes mixed.filter_graph, "[1:v:0]setpts=PTS-STARTPTS,fps=24,scale=1920:804:flags=lanczos,setsar=1"

    # A take larger than the source is brought down to the source.
    big = build(3 => { width: 3840, height: 1608 })
    assert_equal [1920, 804], [big.target.width, big.target.height]
    assert_equal %i[exact exact stretch exact], big.inputs.map(&:fit)
  end

  def test_the_target_rate_is_the_best_take_rate_capped_at_the_source
    assert_equal Rational(24), build(source: source(rate: 30)).target.frame_rate
    assert_equal Rational(30), build(source: source(rate: 30), 2 => { rate: 30 }, 3 => { rate: 60 }).target.frame_rate
    plan = build(source: source(rate: 30), 2 => { rate: 30 })
    assert(plan.filter_graph.split(";").first(4).all? { |chain| chain.include?(",fps=30,") }, "every take is resampled to one rate")
    assert_equal 2160, plan.total_frames
  end

  def test_a_probed_rate_a_hair_off_a_standard_one_is_that_standard_rate
    assert_equal Rational(30_000, 1001), Plan.standard(Rational(2997, 100))
    assert_equal Rational(24), Plan.standard(Rational(24))
    assert_equal Rational(24_000, 1001), Plan.standard(Rational(2_397_602, 100_000))
    assert_equal Rational(239, 10), Plan.standard(Rational(239, 10)), "nowhere near a standard rate: left alone"
    assert_equal Rational(12), Plan.standard(Rational(12))
    assert_equal "30000/1001", build(source: source(rate: Rational(2997, 100)), 1 => { rate: Rational(359_640, 12_001) }).target.rate_label
  end

  def test_an_odd_target_is_made_even_for_yuv420p
    plan = build(**(1..4).to_h { |n| [n, { width: 1485, height: 621 }] })
    assert_equal [1484, 620], [plan.target.width, plan.target.height]
    assert_equal %i[stretch] * 4, plan.inputs.map(&:fit)
  end

  def test_a_take_of_another_shape_is_fitted_inside_and_padded
    plan = build(2 => { width: 608, height: 1080 })

    assert_equal %i[exact pad exact exact], plan.inputs.map(&:fit)
    assert_includes plan.filter_graph,
                    "scale=1920:804:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:804:(ow-iw)/2:(oh-ih)/2:black,"
    assert_includes plan.warnings, "chunk 2: the take's shape differs from 1920x804, so it is padded black"
  end

  def test_a_take_that_runs_short_or_long_is_held_or_trimmed_and_the_operator_is_told
    plan = build(2 => { duration_ms: 24_100 }, 3 => { duration_ms: 26_200 }, 4 => { duration_ms: 12_041 })

    assert_equal [0, -900, 1200, 41], plan.inputs.map(&:adjust_ms)
    assert_equal ["chunk 2's take runs 24.1 s for a 25.0 s window: its last frame is held for 900 ms",
                  "chunk 3's take runs 26.2 s for a 25.0 s window: its last 1200 ms are trimmed"], plan.warnings
    # Held or trimmed, each take is made exactly its window's frames.
    assert_equal [600, 600, 600, 288], plan.filter_graph.scan(/trim=end_frame=(\d+)/).flatten.map(&:to_i)
  end

  def test_a_last_chunk_that_is_nearly_all_overlap_still_fades_in_whole
    # 65.5 s: the last chunk is 60-65.5, five of its 5.5 s shared with chunk 3.
    plan = build(Tiler.windows(65_500))

    assert_equal [4, 1440, 1572], frames(plan).last
    assert_equal [4, 1440, 120], joins(plan).last
    assert_equal 132, plan.inputs.last.frames
    assert_equal 1572, plan.total_frames
    assert_equal 65_500, plan.duration_ms
  end

  def test_a_short_last_chunk_and_a_single_chunk
    short = build(Tiler.windows(41_000))
    assert_equal [[1, 0, 600], [2, 480, 984]], frames(short)
    assert_equal 41_000, short.duration_ms

    one = build(Tiler.windows(9_000))
    assert_empty one.joins
    assert_equal 216, one.total_frames
    assert_equal "[v0]null[vout]", one.filter_graph.split(";").last
  end

  def test_other_tilings_and_a_tiling_with_no_overlap
    api = build(Tiler.windows(40_000, chunk_ms: 15_000, overlap_ms: 5_000))
    assert_equal [[2, 240, 120], [3, 480, 120], [4, 720, 120]], joins(api)
    assert_equal 960, api.total_frames

    cuts = build(Tiler.windows(50_000, chunk_ms: 25_000, overlap_ms: 0))
    assert_equal [[2, 600, 0]], joins(cuts)
    assert_predicate cuts.joins.first, :cut?
    assert_equal "[v0][v1]concat=n=2:v=1:a=0[vout]", cuts.filter_graph.split(";").last
    assert_equal 1200, cuts.total_frames
  end

  def test_windows_that_cannot_be_stitched_are_refused
    window = Tiler::Window
    refused = lambda do |list|
      assert_raises(Plan::Invalid) { build(list) }.message
    end

    assert_equal "a stitch needs at least one take", refused.call([])
    assert_equal "the first chunk must start at 0, not 5000 ms", refused.call([window.new(1, 5_000, 30_000)])
    assert_equal "chunk 2 does not run on from chunk 1", refused.call([window.new(1, 0, 25_000), window.new(2, 0, 25_000)])
    assert_equal "chunk 2 starts 1000 ms after chunk 1 ends: the tiling has a hole",
                 refused.call([window.new(1, 0, 25_000), window.new(2, 26_000, 50_000)])
    assert_equal "chunk 1's take has no picture size",
                 assert_raises(Plan::Invalid) { build(Tiler.windows(9_000), 1 => { width: 0 }) }.message
  end
end
