Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Telnyx TeXML webhooks (token auth, no CSRF). Phase 4 of the multi-tenant
  # migration replaces these with a single /telnyx/webhook for Voice API.
  post "telnyx/voice",     to: "telnyx#voice"
  post "telnyx/screen",    to: "telnyx#screen"
  post "telnyx/clarify",   to: "telnyx#clarify"
  post "telnyx/recording", to: "telnyx#recording"
  post "telnyx/status",    to: "telnyx#status"

  # ntfy notification action buttons (signed-token authed, no session)
  post "ntfy/calls/:call_id/whitelist", to: "ntfy_actions#whitelist", as: :ntfy_whitelist_call
  post "ntfy/calls/:call_id/spam",      to: "ntfy_actions#mark_spam", as: :ntfy_spam_call
  post "ntfy/calls/:call_id/legit",     to: "ntfy_actions#mark_legit", as: :ntfy_legit_call
  post "ntfy/calls/:call_id/report_spam_globally",
       to: "ntfy_actions#report_spam_globally", as: :ntfy_report_spam_globally_call

  # E2E inspector — read-only JSON endpoints for the live e2e suite.
  # Gated by SYNTHETIC_WEBHOOK_TOKEN; returns 401 when the env var is
  # unset, so this surface is invisible in deployments without e2e.
  # Uses query params (not path segments) because call_control_ids
  # contain colons that break Rails path routing (`v3:synthetic-…`).
  get "e2e/call",    to: "e2e_inspector#show_call",    defaults: { format: :json }
  get "e2e/tenant",  to: "e2e_inspector#show_tenant",  defaults: { format: :json }
  get "e2e/contact", to: "e2e_inspector#show_contact", defaults: { format: :json }

  # Authenticated recording playback
  get "recordings/:id", to: "recordings#show", as: :recording

  # Public greeting audio (Telnyx fetches these to <Play> in the call).
  # Three-axis path: phrase × voice × tone.
  get "greetings/:slug/:voice/:tone.wav",
      to: "greetings#show",
      as: :greeting,
      constraints: { slug: /[a-z0-9_]+/, voice: /[a-z0-9_]+/, tone: /[a-z0-9_]+/ }

  # Devise auth: a tenant logs into the admin UI. The /admin/login URL is
  # preserved for muscle memory; the underlying model is now Tenant (was
  # AdminUser).
  devise_for :tenants, path: "admin", path_names: {
    sign_in: "login", sign_out: "logout"
  }

  # Admin panel — every authenticated tenant sees their own data; tenants
  # with admin=true (the operator) additionally manage other tenants.
  namespace :admin do
    root to: "dashboard#index"
    resources :calls, only: [ :index, :show ] do
      member do
        post :mark_spam
        post :mark_legit
        post :block_number
        post :whitelist_number
      end
    end
    resources :contacts
    resources :rules
    resources :recordings, only: [ :index ]
    resources :phrases do
      member { post :rerender }
    end
    resources :tags, only: [ :index, :destroy ]
    resource  :settings, only: [ :show, :update ]
    resource  :profile,  only: [ :show, :edit, :update ]
    resource  :voice_sample, only: [ :create, :destroy ]
    post "voice_sample/clone", to: "voice_samples#enqueue_render", as: :enqueue_voice_clone_render
    resources :tenants
    get "costs", to: "costs#index", as: :costs
  end

  root to: redirect("/admin")
end
