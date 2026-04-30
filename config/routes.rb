Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Telnyx TeXML webhooks (token auth, no CSRF). Phase 4 of the multi-tenant
  # migration replaces these with a single /telnyx/webhook for Voice API.
  post "telnyx/voice",     to: "telnyx#voice"
  post "telnyx/screen",    to: "telnyx#screen"
  post "telnyx/clarify",   to: "telnyx#clarify"
  post "telnyx/recording", to: "telnyx#recording"
  post "telnyx/status",    to: "telnyx#status"

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
    resource  :settings, only: [ :show, :update ]
    resource  :profile,  only: [ :show, :edit, :update ]
    resources :tenants
  end

  root to: redirect("/admin")
end
