Rails.application.routes.draw do
  root "dashboard#index"

  resource :session
  resources :passwords, param: :token

  resources :wallets, only: [ :index, :new, :create, :destroy ] do
    post :sync_now, on: :member
  end

  resources :positions, only: [ :index, :show, :new, :create ] do
    post :sync_now, on: :member
    post :hedge_open_preview, on: :member
    post :hedge_open, on: :member
    post :hedge_rebalance_preview, on: :member
    post :hedge_rebalance, on: :member
    post :hedge_close_preview, on: :member
    post :hedge_close, on: :member
    patch :hedge_venue, on: :member
    get :extended_diagnostics, on: :member
    get :hedge_accounting_diagnostics, on: :member
    get :rewards_fees_diagnostics, on: :member
    get :production_diagnostics, on: :member
    resources :aerodrome_hedge_proposals, only: [ :create ] do
      post :regenerate, on: :collection
    end
  end

  resources :aerodrome_hedge_proposals, only: [] do
    post :mark_reviewed, on: :member
    post :reject, on: :member
  end

  resource :settings, only: [ :edit, :update ]
  get "mellow_autopilot_probe", to: "mellow_autopilot_probes#index"
  post "mellow_autopilot_probe/create_position", to: "mellow_autopilot_probes#create_position", as: :create_mellow_autopilot_position

  resources :hedges, except: [ :index ] do
    post :sync_now, on: :member
  end

  mount MissionControl::Jobs::Engine, at: "/jobs"

  get "up" => "rails/health#show", as: :rails_health_check
end
