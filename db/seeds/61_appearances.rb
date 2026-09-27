# DEMO LOOKS FOR THE MODEL PIPELINE BOARD (/model_pipeline) — one card in every lane.
#
# Why seeded at all, when 51_contents.rb and 52_tasks.rb do the same for their boards: an
# empty five-lane board proves nothing to a human and nothing to the e2e lane. A fresh
# desk or a CI test server should be able to open the page and SEE what each lane means,
# including the two states the whole design turns on — a look dragged ahead of its
# evidence, and a look sent back by a trade.
#
# EVERY ROW IS LOCAL. Nothing here reaches a network or an S3 bucket: the cached-headshot
# rows are ImageCache rows with a plausible key (ImageCache#url is pure string building),
# and the delivered artifacts are rows with an example.com image_url. That matters for CI,
# where 32_headshot_links.rb needs ESPN and may have supplied nothing.
#
# IDEMPOTENT on (person_slug, descriptor) — the pair `index_appearances_live_per_person`
# makes unique among live looks — so re-seeding a desk updates rather than raising.

# Deterministic by slug so the same athletes get the same lanes on every seed, and so a
# spec can name a lane rather than a person.
demo_athletes = Athlete.where(sport: "football").where.not(team_slug: nil).order(:slug).limit(12).to_a

if demo_athletes.length < 8
  safe_puts "  Appearances: skipped (need 8 rostered football athletes, found #{demo_athletes.length})"
else
  def seed_look!(athlete, descriptor, **attrs)
    look = Appearance.find_or_initialize_by(person_slug: athlete.person_slug, descriptor: descriptor)
    look.assign_attributes(attrs)
    look.save!
    look
  end

  def seed_headshot!(athlete)
    ImageCache.find_or_create_by!(owner: athlete, purpose: "headshot", variant: "400") do |cache|
      cache.s3_key = "headshots/nfl/#{athlete.team_slug}/#{athlete.person_slug}/400.png"
      cache.content_type = "image/png"
      cache.bytes = 48_000
    end
  end

  def seed_candidates!(look, count, chosen: 0, judged: 0)
    count.times do |i|
      photo = AppearanceReferencePhoto.find_or_initialize_by(
        appearance_slug: look.slug, image_url: "https://example.com/#{look.slug}/cand-#{i}.jpg"
      )
      photo.assign_attributes(
        source: AppearanceReferencePhoto::SOURCE_SEARCH,
        chosen: i < chosen,
        position: i + 1,
        width: 600, height: 800,
        face_score: (0.85 - (i * 0.03)).round(2),
        title: "#{look.descriptor} candidate #{i + 1}",
        page_url: "https://example.com/#{look.slug}/page-#{i}",
        operator_verdict: (i < judged ? AppearanceReferencePhoto::VERDICT_KEEP : nil),
        rejection_reason: (i >= chosen ? AppearanceReferencePhoto::REJECTED_BEYOND_LIMIT : nil)
      )
      photo.save!
    end
  end

  # THE GENERATOR IS DATA, NEVER A COLUMN NAME. `artifacts.source` says which generator
  # produced the image; the board prints whatever it holds, so a future generator needs no
  # change here or in the view.
  def seed_sheet!(look, source)
    artifact = Artifact.find_or_create_by!(kind: "character_sheet",
                                          image_url: "https://example.com/#{look.slug}/sheet.png") do |row|
      row.source = source
    end
    ArtifactSubject.find_or_create_by!(artifact_slug: artifact.slug, person_slug: look.person_slug) do |row|
      row.appearance_slug = look.slug
      row.ordinal = 1
    end
    artifact
  end

  a = demo_athletes

  # DESIGNED — a look that names no uniform, so nothing downstream can be told what to make.
  seed_look!(a[0], "Unnamed look", colorway: nil, team_slug: nil, generation_notes: nil)

  # DEFINED — a uniform named, no photograph anywhere yet.
  seed_look!(a[1], "#{a[1].team_slug.titleize} home", colorway: "#{a[1].team_slug} home")

  # SOURCE (the floor) — our cached headshot and nothing else. Per the character-sheet
  # recipe this one photograph is enough to generate from; nobody has judged it, so the
  # selection step is still owed.
  seed_headshot!(a[2])
  seed_look!(a[2], "#{a[2].team_slug.titleize} white", colorway: "#{a[2].team_slug} white")

  # SOURCE (a search ran) — twenty candidates, none chosen.
  seed_candidates!(seed_look!(a[3], "#{a[3].team_slug.titleize} alternate",
                              colorway: "#{a[3].team_slug} alternate"), 20)

  # MODEL — a chosen reference set, nothing generated.
  seed_candidates!(seed_look!(a[4], "#{a[4].team_slug.titleize} navy",
                              colorway: "#{a[4].team_slug} navy"), 20, chosen: 6, judged: 4)

  # MODEL — a chosen set whose identity is still training, which is NOT a delivery.
  training = seed_look!(a[5], "#{a[5].team_slug.titleize} road", colorway: "#{a[5].team_slug} road",
                        higgsfield_reference_id: "demo-reference-training",
                        higgsfield_reference_status: Appearances::CreateCharacterReference::PENDING_STATUSES.first)
  seed_candidates!(training, 14, chosen: 5)

  # GENERATION — delivered, and the two cards name two different generators so the board
  # shows provenance without naming a vendor in code.
  ["openai", "operator"].each_with_index do |generator, offset|
    athlete = a[6 + offset]
    seed_headshot!(athlete)
    look = seed_look!(athlete, "#{athlete.team_slug.titleize} game", colorway: "#{athlete.team_slug} game")
    seed_candidates!(look, 12, chosen: 5)
    seed_sheet!(look, generator)
  end

  # TRADED — the freshness case the operator named. The look captured a team the athlete
  # has since left, so it comes BACK to Defined however far downstream it got, and its
  # hand placement is set aside.
  traded_athlete = a[8]
  stale_team = Team.where.not(slug: traded_athlete.team_slug).order(:slug).first&.slug || "chicago-bears"
  seed_headshot!(traded_athlete)
  traded = seed_look!(traded_athlete, "Previous team game", colorway: "previous team game",
                      team_slug: stale_team, stage: "generation")
  seed_candidates!(traded, 18, chosen: 5)
  seed_sheet!(traded, "openai")

  # HAND-PLACED FORWARD — a headshot-only look dragged to Generation. The board honours it
  # and says on the card that the data only supports Source.
  pushed = a[9]
  seed_headshot!(pushed)
  seed_look!(pushed, "#{pushed.team_slug.titleize} pushed ahead",
             colorway: "#{pushed.team_slug} pushed", stage: "generation")

  board = Appearances::Pipeline.build
  safe_puts "  Appearances: #{board[:total]} look(s) — " +
            board[:lanes].map { |lane| "#{lane.key} #{lane.total}" }.join(", ")
end
