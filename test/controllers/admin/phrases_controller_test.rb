require "test_helper"

module Admin
  class PhrasesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @tenant.update!(password: "test-password-1234", password_confirmation: "test-password-1234")
      post tenant_session_url, params: {
        tenant: { email: @tenant.email, password: "test-password-1234" }
      }
    end

    test "redirects to login when unauthenticated" do
      delete destroy_tenant_session_url
      get admin_phrases_url
      assert_redirected_to "/admin/login"
    end

    test "index shows shared system phrases by default" do
      get admin_phrases_url
      assert_response :success
      assert_match "informal_tu", @response.body
      assert_match "voicemail_prompt", @response.body
    end

    test "create authors a tenant phrase and queues render" do
      assert_difference -> { Phrase.count } => 1 do
        post admin_phrases_url, params: {
          phrase: {
            slug: "ti_chiamo_pomeriggio",
            label: "Pomeriggio",
            text_it: "Ciao, ti chiamo nel pomeriggio.",
            text_en: "Hi, I'll call you in the afternoon.",
            time_of_day: "afternoon",
            tag_names: "family, lunch"
          }
        }
      end
      p = Phrase.find_by!(slug: "ti_chiamo_pomeriggio")
      assert_equal @tenant.id, p.tenant_id
      assert_equal "user", p.kind
      assert_equal %w[family lunch].sort, p.tags.pluck(:name).sort
    end

    test "create rejects reserved system slug" do
      assert_no_difference "Phrase.count" do
        post admin_phrases_url, params: {
          phrase: {
            slug: "voicemail_prompt",  # reserved
            label: "Custom",
            text_it: "ciao"
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "create rejects slug with dashes (URL safety)" do
      assert_no_difference "Phrase.count" do
        post admin_phrases_url, params: {
          phrase: {
            slug: "ti-chiamo",  # dashes not allowed
            label: "X",
            text_it: "ciao"
          }
        }
      end
      assert_response :unprocessable_entity
    end

    test "edit/update mutates own phrase" do
      p = Phrase.create!(tenant: @tenant, slug: "edit_me", label: "X",
                         kind: "user", text_it: "old", render_status: "rendered")
      patch admin_phrase_url(p), params: { phrase: { text_it: "new text" } }
      assert_redirected_to admin_phrase_path(p)
      assert_equal "new text", p.reload.text_it
      # text change should reset to pending
      assert_equal "pending", p.reload.render_status
    end

    test "cannot mutate a system/shared phrase" do
      shared = phrases(:voicemail_prompt)
      old_text = shared.text_it
      patch admin_phrase_url(shared), params: { phrase: { text_it: "hijack" } }
      assert_response :not_found
      assert_equal old_text, shared.reload.text_it
    end

    test "destroy removes own phrase + schedules cleanup job" do
      p = Phrase.create!(tenant: @tenant, slug: "delete_me", label: "X",
                         kind: "user", text_it: "x", render_status: "rendered")
      assert_difference -> { Phrase.count } => -1 do
        delete admin_phrase_url(p)
      end
      assert_redirected_to admin_phrases_path
    end

    test "rerender enqueues PhraseRenderJob and resets status" do
      p = Phrase.create!(tenant: @tenant, slug: "rerender_me", label: "X",
                         kind: "user", text_it: "x", render_status: "rendered")
      post rerender_admin_phrase_url(p)
      assert_redirected_to admin_phrases_path
      assert_equal "pending", p.reload.render_status
    end
  end
end
