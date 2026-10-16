require "test_helper"

# [unit] AppMembership: one owner row per (app, user), slug-keyed both ways, and
# the idempotent owner seed (docs/agents/system/app-owners.md).
class AppMembershipTest < ActiveSupport::TestCase
  def owner(email = "owner@turfmonster.example", name: "Turf Owner")
    User.create!(email: email, name: name, role: "viewer")
  end

  test "[unit] an owner row links an app and a user by slug, once" do
    user = owner
    membership = AppMembership.create!(app: apps(:turf_monster), user: user)

    assert_equal [ "turf-monster", user.slug, "owner" ], [ membership.app_slug, membership.user_slug, membership.role ]
    assert_equal [ membership ], user.app_memberships.to_a
    assert_equal [ membership ], apps(:turf_monster).memberships.to_a
    dup = AppMembership.new(app: apps(:turf_monster), user: user)
    assert_not dup.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "[unit] only the owner role is known, to the model and the database" do
    membership = AppMembership.new(app: apps(:turf_monster), user: owner, role: "admin")
    assert_not membership.valid?
    assert_raises(ActiveRecord::StatementInvalid) { membership.save!(validate: false) }
  end

  test "[unit] a user's slug rename carries the membership; deleting the user removes it" do
    user = owner
    AppMembership.create!(app: apps(:turf_monster), user: user)

    user.rename_slug!("turf-owner-renamed")
    assert_equal [ "turf-owner-renamed" ], AppMembership.pluck(:user_slug)

    user.destroy!
    assert_equal 0, AppMembership.count
  end

  test "[unit] seed_owners! links the known owners that exist, says what it did, and is idempotent" do
    turf_owner = owner("alex@turfmonster.media", name: "Alex Turf")

    first = AppMembership.seed_owners!
    assert_equal({ "mcritchie-studio" => "created", "turf-monster" => "created", "cyvasse" => "no app" }, first)
    assert AppMembership.exists?(app_slug: "mcritchie-studio", user_slug: users(:alex).slug)
    assert AppMembership.exists?(app_slug: "turf-monster", user_slug: turf_owner.slug)

    again = AppMembership.seed_owners!
    assert_equal({ "mcritchie-studio" => "present", "turf-monster" => "present", "cyvasse" => "no app" }, again)
    assert_equal 2, AppMembership.count

    assert_equal({ "turf-monster" => "no user" }, AppMembership.seed_owners!({ "turf-monster" => "nobody@example.com" }))
  end
end
