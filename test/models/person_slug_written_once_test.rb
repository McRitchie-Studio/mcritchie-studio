require "test_helper"

# [unit] A person's slug is written once. Athletes, contracts and a dozen other
# tables name a person by slug value, so the hub relies on studio-engine's
# Sluggable to refuse a slug write that does not carry those rows with it.
class PersonSlugWrittenOnceTest < ActiveSupport::TestCase
  setup { @person = people(:josh_allen) }

  test "[unit] a direct slug write is invalid with :readonly and saves nothing" do
    assert_not @person.update(slug: "joshua-allen")

    assert_equal [ { error: :readonly } ], @person.errors.details[:slug]
    assert_equal "josh-allen", Person.find(@person.id).slug
    assert_equal "josh-allen", Athlete.find_by!(slug: "josh-allen-athlete").person_slug
  end

  test "[unit] a name edit keeps the slug, so the rows that name it stay attached" do
    @person.update!(first_name: "Joshua")

    assert_equal "josh-allen", @person.reload.slug
    assert_equal "joshua-allen", @person.name_slug, "the control: the name now derives another slug"
    assert_equal "josh-allen", Athlete.find_by!(slug: "josh-allen-athlete").person_slug
  end

  test "[unit] rename_slug! is the write the validation lets through" do
    @person.rename_slug!("joshua-allen")

    assert_equal "joshua-allen", Person.find(@person.id).slug
    assert @person.valid?, @person.errors.full_messages.to_sentence
    assert @person.update(first_name: "Joshua"), "the renamed record still saves"
  end
end
