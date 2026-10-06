require "test_helper"

# shared/_form_errors is the one validation-error box every hub form renders.
# It replaced five hand-pasted copies drawn in a dark-only red (bg-red-900/50,
# text-red-300) that was unreadable on the light theme; it now draws from the
# danger role's tokens through status_tone.
class FormErrorsPartialTest < ActionView::TestCase
  def invalid_task
    Task.new(title: "").tap(&:validate)
  end

  test "[component] renders one line per message in the danger tokens" do
    task = invalid_task
    render partial: "shared/form_errors", locals: { record: task }

    box = Nokogiri::HTML.fragment(rendered).at_css("[data-test=form-errors]")
    assert box, "the error box renders for an invalid record"
    assert_equal "alert", box["role"]
    assert_equal task.errors.full_messages, box.css("p").map(&:text)

    classes = box["class"].split
    %w[bg-danger/10 border-danger/40 text-danger-ink mb-4].each do |klass|
      assert_includes classes, klass
    end
  end

  test "[component] the box carries no palette colour and no dark: variant" do
    render partial: "shared/form_errors", locals: { record: invalid_task }

    assert_no_match(/\b(bg|text|border)-(red|rose|amber)-\d/, rendered)
    assert_no_match(/\bdark:/, rendered)
  end

  test "[component] spacing sets the margin below the box" do
    render partial: "shared/form_errors", locals: { record: invalid_task, spacing: "mb-3" }

    classes = Nokogiri::HTML.fragment(rendered).at_css("[data-test=form-errors]")["class"].split
    assert_includes classes, "mb-3"
    assert_not_includes classes, "mb-4"
  end

  test "[component] renders nothing for a valid or missing record" do
    render partial: "shared/form_errors", locals: { record: Task.new(title: "Fine") }
    assert_equal "", rendered.strip

    render partial: "shared/form_errors", locals: { record: nil }
    assert_equal "", rendered.strip
  end

  test "[component] a missing record local raises: the partial declares strict locals" do
    assert_raises(ActionView::Template::Error) { render partial: "shared/form_errors" }
  end

  # The five forms that used to paste their own box now render the partial.
  test "[component] no hub view pastes its own errors.full_messages box" do
    pasted = Dir[Rails.root.join("app/views/**/*.erb")].reject { |path| path.end_with?("shared/_form_errors.html.erb") }
      .select { |path| File.read(path).match?(/errors\.full_messages\.each/) }
      .map { |path| path.delete_prefix("#{Rails.root}/") }
    # The contact form keeps its own box: a public page with a heading and a list.
    assert_equal ["app/views/contact_submissions/new.html.erb"], pasted
  end
end
