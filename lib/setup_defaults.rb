class SetupDefaults
  def initialize(env: ENV)
    @env = env
  end

  def report
    {
      supported_hedge_venues: HedgeVenues::SUPPORTED_KEYS,
      default_hedge_execution_venue: HedgeVenues.default_supported(env: env),
      env_example: "DEFAULT_HEDGE_EXECUTION_VENUE=#{HedgeVenues.default_supported(env: env)}",
      first_import_active_by_default: true,
      duplicate_import_behavior: "same user/wallet/external_id/pool updates the existing position instead of creating a duplicate",
      operator_notes: [
        "Wallet import does not activate archived positions.",
        "Dashboard shows active positions only.",
        "Positions can be activated or archived from the Positions UI.",
        "Archive only changes the app record; it does not close the on-chain LP or perps."
      ],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :env
end
