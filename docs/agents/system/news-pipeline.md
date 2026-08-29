# News Pipeline

## Overview

The News pipeline is a multi-stage content enrichment workflow. Articles enter as raw tweets/links and are progressively enriched by agents through 6 stages.

```
NEW → REVIEWED → PROCESSED → REFINED → CONCLUDED → ARCHIVED
 ↑       ↑          ↑          ↑           ↑          ↑
Intake  Mason      Mack       Alex    Turf Monster   Alex
```

## Stages & Agent Assignments

| Stage | Agent | What happens | Fields populated |
|-------|-------|-------------|-----------------|
| **New** | Intake (automated) | Raw article/tweet ingested | title, url, x_post_id, x_post_url, author, published_at |
| **Reviewed** | Mason | Identify people, teams, action | primary_person, primary_team, primary_action, secondary_person, secondary_team, article_image_url |
| **Processed** | Mack (automated) | Generate slugs from names | primary_person_slug, primary_team_slug, secondary_person_slug, secondary_team_slug |
| **Refined** | Alex | Summarize, add tone | title_short, summary, feeling, feeling_emoji, what_happened |
| **Concluded** | Turf Monster | Form opinion, suggest follow-ups | opinion, callback |
| **Archived** | Alex | Done — no longer active | archived_at |

## Services

All services live in `app/services/news/`. They reopen the `News` class (not a module — `class News`, not `module News`).

### `News::Intake`
Fetches the latest Adam Schefter tweet not already in the DB.

```ruby
news = News::Intake.new.call
# => News record or nil
```

- Uses X API v2 (`GET /2/users/:id/tweets`)
- Resolves `AdamSchefter` → user ID (cached per instance)
- Deduplicates by `x_post_id`
- Extracts first URL from tweet text
- Requires `X_BEARER_TOKEN` env var

### `News::Review` (Mason)
```ruby
News::Review.new(news).call(
  primary_person: "Patrick Mahomes",
  primary_team: "Kansas City Chiefs",
  primary_action: "extended",
  secondary_person: "Dak Prescott",
  secondary_team: "Dallas Cowboys",
  article_image_url: "https://example.com/image.jpg"
)
```

### `News::Process` (Mack) — fully automated
```ruby
News::Process.new(news).call
# No input needed — derives slugs from existing person/team fields
# "Patrick Mahomes" → "patrick-mahomes"
```

Also available via the UI: **Process (auto)** button on the show page when stage is `reviewed`.

### `News::Refine` (Alex)
```ruby
News::Refine.new(news).call(
  title_short: "Mahomes extends with Chiefs",
  summary: "Patrick Mahomes agrees to a record extension.",
  feeling: "excited",
  feeling_emoji: "🔥",
  what_happened: "Chiefs locked up their franchise QB."
)
```

### `News::Conclude` (Turf Monster)
```ruby
News::Conclude.new(news).call(
  opinion: "Smart move by KC — stability at QB is everything.",
  callback: "Watch for contract details and cap implications."
)
```

## Rake Task

```bash
bin/rails news:intake    # Fetch latest Schefter tweet
```

## Credentials Setup

### X (Twitter) API — Bearer Token

1. **1Password**: Stored in `agent.turf.x` in the agent vault
   ```bash
   op item get zz3uigmkrwjlnnksst33butc4e --vault txqp6ijdo3ujsfhsfzdj5h5dzq --field "Bearer Token" --reveal
   ```

2. **Local .env**: Add to the McRitchie Studio app-local `.env`:
   ```
   X_BEARER_TOKEN=<bearer-token-from-1password>
   ```

3. **Heroku** (production): Set via config var:
   ```bash
   heroku config:set X_BEARER_TOKEN=<token> --app mcritchie-studio
   ```

### X Developer Portal

- **Login**: `alex@turfmonster.com` (credentials in 1Password `agent.turf.x`)
- **Portal**: https://developer.x.com/en/portal/dashboard
- **Tier**: Free (read-only, 1 app, 1500 tweets/month read)
- **Rate limits**: 1 request per 15 minutes for user tweets endpoint

## Onboarding Checklist

When starting fresh (new machine, new DB, or new agents suite):

### 1. Database
```bash
bin/rails db:migrate
bin/rails db:seed        # Creates 7 sample news articles across all stages
```

### 2. X API Credentials
```bash
# Fetch bearer token from 1Password
export OP_SERVICE_ACCOUNT_TOKEN='<token-from-zshrc>'
X_TOKEN=$(op item get zz3uigmkrwjlnnksst33butc4e \
  --vault txqp6ijdo3ujsfhsfzdj5h5dzq \
  --field "Bearer Token" --reveal)

# Add to app-local .env
echo "X_BEARER_TOKEN=$X_TOKEN" >> /Users/alex/projects/mcritchie-studio/.env
```

Or manually: copy the Bearer Token from 1Password and paste into `.env`.

### 3. Verify Intake
```bash
bin/rails news:intake
# Expected: "Created: <tweet text> (news-xxxxxxxxxxxx)"
```

### 4. Walk the Pipeline (console)
```ruby
n = News.last

# Step 1: Review (Mason)
News::Review.new(n).call(
  primary_person: "...", primary_team: "...", primary_action: "...",
  secondary_person: nil, secondary_team: nil, article_image_url: nil
)

# Step 2: Process (Mack) — automated
News::Process.new(n).call

# Step 3: Refine (Alex)
News::Refine.new(n).call(
  title_short: "...", summary: "...",
  feeling: "...", feeling_emoji: "...", what_happened: "..."
)

# Step 4: Conclude (Turf Monster)
News::Conclude.new(n).call(
  opinion: "...", callback: "..."
)
```

### 5. Verify UI
- Kanban board: http://localhost:3000/news
- Article detail: click any card
- Workflow docs: http://localhost:3000/news/workflow

## Architecture Notes

- **Free movement**: Articles can move backward/forward between any stages (unlike Tasks which enforce transitions)
- **Stage timestamps**: Each stage records when it was reached; moving backward preserves prior timestamps
- **Position system**: Cards are ordered within each Kanban column; position resets on stage change
- **No model associations**: News stores person/team names and slugs as strings — no FK relationships to Player/Team models (yet)
- **Service namespace**: Services use `class News` (reopening the AR model class), not `module News`, to avoid TypeError collision
