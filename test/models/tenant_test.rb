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
end
