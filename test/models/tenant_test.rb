require "test_helper"

class TenantTest < ActiveSupport::TestCase
  setup do
    @default = tenants(:default)
    @other   = tenants(:other)
  end

  test "default scope finds the default tenant" do
    assert_equal @default, Tenant.default
  end

  test "default tenant is unique (DB-level partial unique index)" do
    duplicate = Tenant.new(
      email: "extra@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234",
      slug: "extra",
      mobile_number: "+393881234567",
      default_tenant: true
    )
    assert_not duplicate.valid?
    assert duplicate.errors[:default_tenant].any?
  end

  test "slug must be present and well-formed" do
    t = Tenant.new(slug: nil)
    assert_not t.valid?
    assert t.errors[:slug].any?

    t.slug = "BAD spaces"
    assert_not t.valid?
    assert t.errors[:slug].any?

    t.slug = "ok-slug.123"
    t.email = "x@example.test"
    t.password = "test-password-1234"
    t.password_confirmation = "test-password-1234"
    assert t.valid?, t.errors.full_messages.inspect
  end

  test "mobile_number must be E.164 if present, unique" do
    t = Tenant.new(
      email: "m1@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234",
      slug: "m1",
      mobile_number: "not-a-number"
    )
    assert_not t.valid?
    assert t.errors[:mobile_number].any?

    t.mobile_number = @default.mobile_number
    assert_not t.valid?, "mobile_number must be unique across tenants"
    assert t.errors[:mobile_number].any?

    t.mobile_number = "+393889876543"
    assert t.valid?, t.errors.full_messages.inspect
  end

  test "dedicated_number must be E.164 and unique-when-present" do
    t = Tenant.new(
      email: "d1@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234",
      slug: "d1",
      dedicated_number: "no"
    )
    assert_not t.valid?

    t.dedicated_number = nil
    assert t.valid?, "nil dedicated_number is allowed"

    @other.update!(dedicated_number: "+390591111111")
    t.dedicated_number = "+390591111111"
    assert_not t.valid?, "dedicated_number must be unique-when-present"
  end

  test "default_forward_back_to_mobile fills forward_back_number from mobile_number" do
    t = Tenant.create!(
      email: "fb@example.test",
      password: "test-password-1234",
      password_confirmation: "test-password-1234",
      slug: "fb",
      mobile_number: "+393881111111"
    )
    assert_equal "+393881111111", t.forward_back_number
  end

  test "spam_sensitivity must be 0..1" do
    t = @default
    t.spam_sensitivity = 2.0
    assert_not t.valid?
    t.spam_sensitivity = 0.5
    assert t.valid?
  end

  test "max_calls_per_caller_per_day must be 1..1000" do
    t = @default
    t.max_calls_per_caller_per_day = 0
    assert_not t.valid?
    t.max_calls_per_caller_per_day = 50
    assert t.valid?
  end

  test "screening_speech_timeout accepts integer or 'auto'" do
    t = @default
    t.screening_speech_timeout = "auto"
    assert t.valid?
    t.screening_speech_timeout = "5"
    assert t.valid?
    t.screening_speech_timeout = "garbage"
    assert_not t.valid?
  end

  test "greeting_voice must be in allowed set" do
    t = @default
    t.greeting_voice = "robot"
    assert_not t.valid?
    t.greeting_voice = "im_nicola"
    assert t.valid?
  end

  test "railsdav_username regex matches" do
    t = @default
    t.railsdav_username = "BAD spaces"
    assert_not t.valid?
    t.railsdav_username = "valid.user-1"
    assert t.valid?
  end

  test "super_admin? mirrors admin column" do
    assert_predicate @default, :super_admin?
    assert_not_predicate @other, :super_admin?
  end

  test "display_name falls back through name → slug → email" do
    @other.update!(name: nil)
    assert_equal "other", @other.display_name
    # slug is normally validated as present; update_columns bypasses validation
    # solely to verify the display_name fallback chain.
    @other.update_columns(slug: "")
    assert_equal "other-tenant@example.test", @other.display_name
  end

  test "tenant cannot be destroyed while it owns calls (restrict_with_error)" do
    @default.calls.first  # ensure fixture exists
    @default.destroy
    assert @default.errors[:base].any?, "expected destroy to be blocked"
  end

  test "voice_clone_active requires consent and sample" do
    t = @default
    t.update_columns(voice_sample_path: nil, voice_clone_consent_at: nil, voice_clone_active: false)

    t.voice_clone_active = true
    refute t.valid?
    assert_includes t.errors[:voice_clone_active], "requires consent before activation"
    assert_includes t.errors[:voice_clone_active], "requires a voice sample to be uploaded"

    t.voice_clone_consent_at = Time.current
    refute t.valid?
    assert_includes t.errors[:voice_clone_active], "requires a voice sample to be uploaded"

    t.voice_sample_path = "tenant_1.wav"
    assert t.valid?, t.errors.full_messages.inspect
  end

  test "cloned_voice_dir uses _t<id> prefix that can't collide with Kokoro voice ids" do
    assert_equal "_t#{@default.id}", @default.cloned_voice_dir
    refute @default.cloned_voice_dir.match?(/\A[a-z]{2}_[a-z]/), "_t prefix avoids Kokoro voice patterns"
  end

  test "voice_clone_ready? requires both active and rendered_at" do
    t = @default
    t.update_columns(voice_sample_path: "tenant_1.wav",
                     voice_clone_consent_at: Time.current,
                     voice_clone_active: true,
                     voice_clone_rendered_at: nil)
    refute t.voice_clone_ready?
    t.update!(voice_clone_rendered_at: Time.current)
    assert t.voice_clone_ready?
  end

  test "voice_rotation_voices accepts known voices and the tenant's own clone dir" do
    @default.voice_rotation_voices = "if_sara,im_nicola,#{@default.cloned_voice_dir}"
    assert @default.valid?, @default.errors.full_messages.to_sentence
  end

  test "voice_rotation_voices rejects an unknown voice (path-traversal guard)" do
    @default.voice_rotation_voices = "im_nicola,../../etc/cron.d/x"
    refute @default.valid?
    assert_includes @default.errors[:voice_rotation_voices].to_sentence, "../../etc/cron.d/x"
  end

  test "voice_rotation_voices rejects another tenant's clone dir" do
    @default.voice_rotation_voices = "im_nicola,_t#{@other.id}"
    refute @default.valid?
    assert_includes @default.errors[:voice_rotation_voices].to_sentence, "_t#{@other.id}"
  end

  test "voice_rotation_voices may be blank" do
    @default.voice_rotation_voices = ""
    assert @default.valid?, @default.errors.full_messages.to_sentence
  end

  test "auto_blacklist_threshold rejects 0 but allows nil (nil is the off switch)" do
    @default.auto_blacklist_threshold = 0
    refute @default.valid?, "0 must be rejected (use nil to disable)"
    @default.auto_blacklist_threshold = nil
    assert @default.valid?, @default.errors.full_messages.to_sentence
  end

  # === SEC-1: deactivated tenants cannot authenticate ===

  test "active_for_authentication? is false when the tenant is deactivated" do
    @other.update_columns(active: false)
    refute @other.active_for_authentication?
    assert_equal :inactive, @other.inactive_message
  end

  test "active_for_authentication? is true for an active tenant" do
    assert @default.active?
    assert @default.active_for_authentication?
  end

  # === SEC-2: ntfy_url SSRF validation ===

  test "ntfy_url allows blank and the 'disabled' sentinel" do
    @default.ntfy_url = ""
    assert @default.valid?, @default.errors.full_messages.to_sentence
    @default.ntfy_url = "disabled"
    assert @default.valid?, @default.errors.full_messages.to_sentence
  end

  test "ntfy_url allows a public https URL and a bare public hostname" do
    @default.ntfy_url = "https://ntfy.sh/my-topic"
    assert @default.valid?, @default.errors.full_messages.to_sentence
    @default.ntfy_url = "https://ntfy.example.com/topic"
    assert @default.valid?, @default.errors.full_messages.to_sentence
  end

  test "ntfy_url rejects loopback, private, link-local, and metadata IP literals" do
    %w[
      http://127.0.0.1/x
      http://169.254.169.254/latest/meta-data/
      https://10.0.0.5/topic
      http://192.168.1.10/topic
      https://[::1]/topic
    ].each do |bad|
      @default.ntfy_url = bad
      refute @default.valid?, "#{bad} must be rejected"
      assert @default.errors[:ntfy_url].any?, "#{bad} should add an ntfy_url error"
    end
  end

  test "ntfy_url rejects a non-http(s) scheme" do
    @default.ntfy_url = "ftp://example.com/x"
    refute @default.valid?
    assert @default.errors[:ntfy_url].any?
  end
end
