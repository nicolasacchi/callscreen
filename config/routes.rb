Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Telnyx TeXML webhooks (token auth, no CSRF)
  post "telnyx/voice",     to: "telnyx#voice"
  post "telnyx/screen",    to: "telnyx#screen"
  post "telnyx/recording", to: "telnyx#recording"
  post "telnyx/status",    to: "telnyx#status"

  # Authenticated recording playback
  get "recordings/:id", to: "recordings#show", as: :recording

  # Devise admin auth
  devise_for :admin_users, path: "admin", path_names: {
    sign_in: "login", sign_out: "logout"
  }

  # Admin panel
  namespace :admin do
    root to: "dashboard#index"
    resources :calls, only: [ :index, :show ] do
      member do
        post :mark_spam
        post :mark_legit
        post :block_number
      end
    end
    resources :contacts
    resources :rules
    resource :settings, only: [ :show, :update ]
  end

  root to: redirect("/admin")
end
