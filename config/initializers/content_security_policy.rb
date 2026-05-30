# Content Security Policy for the admin UI (csp_meta_tag is rendered in both
# layouts). The admin panel guards call recordings + cross-tenant data, so a
# baseline CSP is real defense-in-depth behind ERB auto-escaping (SEC-2/UI-2).
#
# script-src / style-src keep 'unsafe-inline' for now because the layout uses
# an inline <style> block, an inline service-worker <script>, and inline
# onchange="this.form.submit()" handlers. The remaining directives
# (frame-ancestors, object-src, base-uri, form-action) are strict and add
# genuine clickjacking / base-tag / form-hijack protection at zero breakage
# risk. P2 (admin UX) migrates the inline handlers to Stimulus + nonces so
# 'unsafe-inline' can be dropped from script-src.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.font_src        :self, :data
    policy.img_src         :self, :data
    policy.object_src      :none
    policy.script_src      :self, :unsafe_inline
    policy.style_src       :self, :unsafe_inline
    policy.connect_src     :self
    policy.media_src       :self
    policy.base_uri        :self
    policy.form_action     :self
    policy.frame_ancestors :none
  end
end
