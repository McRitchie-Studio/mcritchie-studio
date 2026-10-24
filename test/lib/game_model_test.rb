# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/game_model/cli"

# [unit] bin/game-model's mechanics with the network, the image API, ArcFace,
# Apple Vision and ImageMagick faked: only team and league hosts are fetched, a
# club gallery page parses to its photos, the edits request pins the dated model,
# the prompts carry the lessons of the hand-built sheets (the three-quarter
# geometry, the build anchors), the gate picks the best attempt and flags the
# floor, the stitch lays out 2 + 6, and each stage wires its references in order
# under the 16-image cap, and the performance sheet takes 16 front-on cells,
# 4x4, from the face pack and today's jersey. The paid path itself was proven
# by real runs.
class GameModelTest < Minitest::Test
  SPEC = {
    "name" => "Test Player", "espn_id" => "123", "descriptor" => "Bears white · 2026 Week 6 at ATL", "number" => 18,
    "uniform" => "UNIFORM TEXT.", "jersey_panel" => "the WHITE jersey", "specifics_front" => "number 18 FRONT",
    "specifics_back" => "WILLIAMS 18 BACK", "back_panel" => "the name on the back", "hair" => "short curls",
    "facial_hair" => "a mustache", "build" => "6 feet 1 inch",
    "face_refs" => (1..12).map { |i| "refs/f#{i}.jpg" }, "uniform_refs" => %w[u1.jpg u2.jpg],
    "build_refs" => %w[b1.jpg b2.jpg b3.jpg b4.jpg b5.jpg b6.jpg], "game_refs" => %w[g1.jpg g2.jpg g3.jpg]
  }.freeze

  def test_only_team_and_league_hosts_are_fetched
    assert GameModel::Hosts.allowed?("https://www.chicagobears.com/photos/x")
    assert GameModel::Hosts.allowed?("https://static.clubs.nfl.com/image/upload/a.jpg")
    assert GameModel::Hosts.allowed?("https://a.espncdn.com/i/headshots/nfl/players/full/1.png")
    refute GameModel::Hosts.allowed?("https://media.gettyimages.com/photos/a.jpg")
    refute GameModel::Hosts.allowed?("https://evilchicagobears.com/x"), "a suffix that is not a subdomain"
    refute GameModel::Hosts.allowed?("http://www.chicagobears.com/x"), "https only"
    error = assert_raises(GameModel::Failure) { GameModel::Hosts.check!("https://www.imagn.com/a.jpg") }
    assert_match "wire/agency", error.message
  end

  def test_a_gallery_page_parses_to_its_photos
    html = '<script>{"datePublished":"2026-10-18T19:00:00Z"}</script>' \
           '<a href="/photos/gameday-gallery-bears-at-falcons"></a><a href="/photos/all"></a>' \
           '<img alt="QB Caleb Williams &amp; WR" class="x" data-src="https://static.clubs.nfl.com/image/upload/t_new_photo_album_3x/t_lazy/bears/a.jpg">' \
           '<img alt="dup" data-src="https://static.clubs.nfl.com/image/upload/t_new_photo_album_3x/t_lazy/bears/a.jpg">'
    assert_equal [{ "alt" => "QB Caleb Williams & WR", "url" => "https://static.clubs.nfl.com/image/upload/t_new_photo_album_2x/bears/a.jpg" }],
                 GameModel::Gallery.photos(html)
    assert_equal ["gameday-gallery-bears-at-falcons"], GameModel::Gallery.slugs(html)
    assert_equal "2026-10-18", GameModel::Gallery.date(html)
  end

  def test_the_edits_request_pins_the_dated_model_and_sends_refs_in_order
    Dir.mktmpdir do |dir|
      refs = %w[a.jpg b.png].map { |n| File.join(dir, n).tap { |p| File.write(p, n) } }
      body = GameModel::ImageEdits.multipart("B", prompt: "P", refs: refs, size: "1024x1024")
      assert_includes body, "name=\"model\"\r\n\r\ngpt-image-2.5-sunburst-2026-09-08\r\n"
      assert_includes body, "name=\"quality\"\r\n\r\nhigh\r\n"
      assert_operator body.index("a.jpg"), :<, body.index("b.png")
      assert_includes body, "filename=\"b.png\"\r\nContent-Type: image/png"
      assert_raises(GameModel::Failure) { GameModel::ImageEdits.multipart("B", prompt: "P", refs: refs * 9, size: "1024x1024") }
    end
  end

  def test_the_prompts_carry_the_hand_built_lessons
    spec = GameModel::Spec.new(".", SPEC)
    tq = GameModel::Prompts.panel(spec, "tq_left")
    assert_includes tq, "his nose and eyes point toward the left edge"
    refute_includes tq, "toward the LEFT side of the frame", "the wording that faced right 4 times in 4"
    assert_includes GameModel::Prompts.full_front(spec, faces: 6, builds: 5, games: 2), "fingertips reach only the upper-middle"
    assert_includes GameModel::Prompts.face_view(spec, "front_neutral"), "his facial hair (a mustache)"
    assert_includes GameModel::Prompts.panel(spec, "rear"), "seen from the back: the name on the back"
    iced = GameModel::Prompts.panel(spec, "look_up", iced: true)
    assert_includes iced, "RINGS SHOT"
    assert_includes iced, "black acetate frames"
    assert_includes GameModel::Prompts.body_template(spec, "front", build_refs: 5), "NO numbers, NO name"
  end

  def test_a_spec_names_what_it_is_missing
    error = assert_raises(GameModel::Failure) { GameModel::Spec.new(".", SPEC.merge("uniform" => "", "face_refs" => [])) }
    assert_equal "spec.yml is missing uniform, face_refs", error.message
  end

  def test_the_gate_picks_the_best_attempt_and_flags_the_floor
    scores = { "front_neutral_1" => 0.76, "front_neutral_2" => 0.81, "rear_1" => nil, "tq_left_1" => 0.66 }
    assert_equal({ "front_neutral" => ["front_neutral_2", 0.81], "rear" => ["rear_1", nil], "tq_left" => ["tq_left_1", 0.66] },
                 GameModel::Gate.best(scores))
    assert_equal ["tq_left_1"], GameModel::Gate.below_floor(scores)
    assert_empty GameModel::Gate.below_floor({ "tq_back_1" => 0.21, "rear_2" => 0.05 }), "back views have no face to floor"
    centre = GameModel::Gate.centroid([[1.0, 0.0], [0.0, 1.0], nil])
    assert_in_delta 0.7071, centre.first, 0.001
  end

  def test_the_stitch_lays_out_two_bodies_and_six_panels
    cmds = GameModel::Stitch.commands(fronts: %w[f b], panels: %w[p1 p2 p3 p4 p5 p6], out: "s.png", work: "w")
    assert_equal 3, cmds.size
    assert_equal %w[f b], cmds[0].values_at(2, 7)
    assert_equal "w/s-right.png", cmds[1].last, "temp halves are named after the sheet"
    assert_equal %w[p1 p2 p3], cmds[1][2, 3]
    assert_equal %w[p4 p5 p6], cmds[1][16, 3]
    assert_equal "s.png", cmds[2].last
    assert_raises(GameModel::Failure) { GameModel::Stitch.commands(fronts: %w[f], panels: [], out: "s", work: "w") }
  end

  def test_each_stage_wires_its_references_in_order_under_the_cap
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "spec.yml"), SPEC.merge("picks" => { "body" => { "front" => "front_2" } }).to_yaml)
      %w[facepack body full iced_full].each do |stage|
        names = stage == "facepack" ? GameModel::Prompts::FACE_VIEWS.keys : %w[front back]
        names.each { |n| [1, 2].each { |i| touch(dir, "out/#{stage}/#{n}_#{i}.png") } }
      end
      File.write(File.join(dir, "out/facepack/scores.json"), '{"front_neutral_1":0.71,"front_neutral_2":0.80}')
      cli = GameModel::Cli.new([], out: StringIO.new)
      spec = GameModel::Spec.load(dir)

      face = cli.jobs_for(spec, dir, "facepack", 1)
      assert_equal 10, face.size
      assert_equal 12, face.first[:refs].size

      full = cli.jobs_for(spec, dir, "full", 1)
      front = full.find { |j| j[:out].end_with?("/front_1") }
      assert_equal "front_neutral_2.png", File.basename(front[:refs].first), "the gate's best when no pick is written"
      assert_equal "front_2.png", File.basename(front[:refs][6]), "the agent's pick wins"
      assert_equal %w[b1.jpg b2.jpg b3.jpg b4.jpg b5.jpg g1.jpg g2.jpg], front[:refs].drop(7).map { |p| File.basename(p) }
      assert_operator front[:refs].size, :<=, GameModel::MAX_REFS

      panels = cli.jobs_for(spec, dir, "iced_panels", 1)
      assert_equal 6, panels.size
      rings = panels.find { |j| j[:out].end_with?("/look_up_1") }
      assert_includes rings[:prompt], "RINGS SHOT"
      assert_equal "iced_full", File.basename(File.dirname(rings[:refs][4])), "iced panels copy the iced full body"
      assert_equal "g3.jpg", File.basename(rings[:refs].last)
    end
  end

  def test_the_performance_stage_needs_only_his_face_and_todays_jersey
    Dir.mktmpdir do |dir|
      heads = SPEC.slice(*GameModel::Spec::PERFORMANCE)
      File.write(File.join(dir, "spec.yml"), heads.merge("picks" => { "facepack" => { "tq_left" => "tq_left_2" } }).to_yaml)
      GameModel::Prompts::FACE_VIEWS.each_key { |n| [1, 2].each { |i| touch(dir, "out/facepack/#{n}_#{i}.png") } }
      cli = GameModel::Cli.new([], out: StringIO.new)
      spec = GameModel::Spec.load(dir, needs: GameModel::Spec::PERFORMANCE)
      assert_raises(GameModel::Failure) { GameModel::Spec.load(dir) }
      assert_equal 10, cli.jobs_for(GameModel::Spec.load(dir, needs: GameModel::Spec::FACEPACK), dir, "facepack", 1).size,
                   "a heads-only spec can build its face pack"

      jobs = cli.jobs_for(spec, dir, "performance", 1)
      assert_equal 16, jobs.size
      assert_equal GameModel::Prompts::PERFORMANCE_ORDER, jobs.map { |j| File.basename(j[:out]).delete_suffix("_1") }
      refs = jobs.first[:refs].map { |p| File.basename(p) }
      assert_equal %w[front_neutral_1.png front_smile_1.png tq_left_2.png tq_right_1.png profile_right_1.png g2.jpg g3.jpg], refs,
                   "face model first (the pick wins), then the last two game refs"
      assert_equal "1024x1024", jobs.first[:size]
    end
  end

  def test_each_performance_cell_names_its_face_or_mouth
    prompts = GameModel::Prompts::PERFORMANCE_ORDER.to_h { |c| [c, GameModel::Prompts.performance(SPEC, c, faces: 5, games: 2)] }
    assert_equal 16, prompts.size
    assert_includes prompts["singing"], "eyes closed"
    assert_includes prompts["oo"], "pucker"
    assert_includes prompts["fv"], "upper front teeth clearly visible and pressing down ON his lower lip"
    assert_includes prompts["mbp"], "lips pressed firmly together"
    prompts.each_value do |text|
      assert_includes text, "facing the camera straight on"
      assert_includes text, "the WHITE jersey"
      assert_includes text, "identity must not change"
    end
    assert_equal 16, prompts.values.uniq.size, "every cell has its own prompt"
  end

  def test_the_performance_stitch_is_a_captioned_four_by_four
    cells = (1..16).map { |i| "c#{i}.png" }
    cmd = GameModel::Stitch.performance_commands(cells: cells, out: "p.png", font: "F.ttf").first
    assert_equal "4x4", cmd[cmd.index("-tile") + 1]
    assert_equal "NEUTRAL", cmd[cmd.index("c1.png") - 1]
    assert_equal "BIG SMILE", cmd[cmd.index("c2.png") - 1]
    assert_equal "L/TH", cmd[cmd.index("c16.png") - 1]
    assert_equal "p.png", cmd.last
    assert_raises(GameModel::Failure) { GameModel::Stitch.performance_commands(cells: cells.first(15), out: "p", font: "F") }
  end

  def test_a_coach_spec_files_by_person_under_his_name_folder
    coach = SPEC.reject { |k, _| k == "espn_id" }.merge("person" => { "first_name" => "Dave", "last_name" => "Canales", "vocation" => "coach" },
                                                        "team_slug" => "carolina-panthers")
    spec = GameModel::Spec.new(".", coach)
    assert_equal "dave-canales", spec.folder
    payload = GameModel::Filing.payload(spec, [])
    assert_equal({ "first_name" => "Dave", "last_name" => "Canales", "vocation" => "coach" }, payload[:person])
    assert_equal "carolina-panthers", payload[:team_slug]
    refute payload.key?(:espn_id)
    refute payload.key?(:jersey_number), "a coach's look carries no jersey number"
    assert_equal "123", GameModel::Spec.new(".", SPEC).folder
    assert_raises(GameModel::Failure) { GameModel::Spec.new(".", SPEC.reject { |k, _| k == "espn_id" }).folder }
  end

  def test_file_dry_run_uploads_and_posts_nothing
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "spec.yml"), SPEC.to_yaml)
      touch(dir, "sheet/test-player-base.png")
      shell_calls = []
      out = StringIO.new
      GameModel::Cli.new(["file", dir, "--dry-run"], out: out, shell: ->(*cmd) { shell_calls << cmd }).run
      assert_equal "magick", shell_calls.first.first
      assert_match %r{would upload .*test-player-base\.jpg to r2://mcritchie-studio-dev/character-sheets/game-models/123/}, out.string
      assert_match %r{would POST http://localhost:3000/api/v1/game_looks .*"variant":"base"}, out.string
    end
  end

  def test_file_refuses_a_second_run_once_filed
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "spec.yml"), SPEC.to_yaml)
      touch(dir, "sheet/test-player-base.png")
      touch(dir, "filed_dev.json")
      error = assert_raises(GameModel::Failure) { GameModel::Cli.new(["file", dir], out: StringIO.new, shell: ->(*) { }).run }
      assert_match "already filed", error.message
    end
  end

  private

  def touch(dir, path)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x")
  end
end
