# frozen_string_literal: true

# releases.confirmed_by NAMES THE OWNER, NOT THE PERSONA SOUL (rename-loose-ends).
#
# The only writer of confirmed_by is Release#ship!, through `bin/release ship` and
# `bin/release finalize`, whose `--by` defaulted to ENV["USER"]: the Mac login,
# `alex`. Since ritch-renamed-alex (2026-10-25) `alex` is the persona soul's slug,
# so those rows read as the agent. The default is now "Alex McRitchie"
# (ShipAuthority::OWNER), and this moves the rows the old default wrote.
#
# WHICH `alex` ROWS. Production, read-only, 2026-10-27: 524 rows held `alex`, in
# two populations that never overlap in time.
#   * 367 confirmed 2026-06-20 .. 2026-09-24 05:23 UTC. Written as `alex` while
#     `alex` was BOTH the login and the orchestrator soul's slug; RenameAlexSoulToXan
#     (2026-09-24, it counted these same 367) ruled them the soul and moved them to
#     `xan`, RenameXanSoulToRay to `ray`, RenameRaySoulToAlex back to `alex`.
#     Their deploy_prod events were rewritten in the same RenameRaySoulToAlex
#     transaction (xmin = that migration's schema_migrations row). Which `alex`
#     they meant is not recoverable, so they keep the renames' ruling. Untouched.
#   * 157 confirmed 2026-09-25 13:19 UTC .. today. Written as `alex` while `alex`
#     was NOT a soul slug (xan, then ray, held the seat). No rename migration ever
#     rewrote them or their deploy_prod event (every one carries actor `alex`,
#     untouched by RenameRaySoulToAlex). So `alex` there is the login default: the
#     owner. These move. (The ~151 the reviewers counted, plus confirmations since.)
# CUTOFF splits the two at the first second of 2026-09-25 UTC, between the last
# row of the first population and the first of the second.
#
# REVERSIBLE, EXACTLY. `up` marks each row it changes (metadata MARK => "alex"),
# and `down` restores only marked rows, so an owner confirmation written after
# `up` keeps its name. IDEMPOTENT: a second `up` finds no post-cutoff `alex` row.
# updated_at is left alone: this corrects a label, the row did not change.
#
# Proof: test/db/confirmed_by_alex_to_alex_mcritchie_migration_test.rb.
class ConfirmedByAlexToAlexMcritchie < ActiveRecord::Migration[8.1]
  FROM = "alex"
  OWNER = "Alex McRitchie"
  CUTOFF = Time.utc(2026, 9, 25)
  MARK = "confirmed_by_was"

  def up
    return unless ready?

    rows = execute(<<~SQL.squish).cmd_tuples
      UPDATE releases
         SET confirmed_by = #{quote(OWNER)},
             metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{#{MARK}}', to_jsonb(#{quote(FROM)}::text))
       WHERE confirmed_by = #{quote(FROM)} AND confirmed_at >= #{quote(CUTOFF)}
    SQL
    say "releases.confirmed_by: #{rows} #{FROM} → #{OWNER} (confirmed on or after #{CUTOFF.iso8601})"
  end

  def down
    return unless ready?

    rows = execute(<<~SQL.squish).cmd_tuples
      UPDATE releases
         SET confirmed_by = #{quote(FROM)}, metadata = metadata - #{quote(MARK)}
       WHERE confirmed_by = #{quote(OWNER)} AND metadata ->> #{quote(MARK)} = #{quote(FROM)}
    SQL
    say "releases.confirmed_by: #{rows} #{OWNER} → #{FROM} (the rows up marked)"
  end

  private

  def ready?
    connection.table_exists?(:releases) &&
      connection.column_exists?(:releases, :confirmed_by) && connection.column_exists?(:releases, :metadata)
  end

  def quote(value) = connection.quote(value)
end
