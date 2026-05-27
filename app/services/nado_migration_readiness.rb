class NadoMigrationReadiness
  def initialize(snapshot: nil, env: ENV)
    @snapshot = snapshot
    @env = env
  end

  def report
    blockers = [
      "Nado migration readiness is not proven.",
      "Nado live migration path not implemented.",
      "Nado close/open readback proof required."
    ]
    current_short = decimal_string(snapshot&.nado_short_eth)

    {
      status: "not_implemented",
      nado_position_read_available: false,
      nado_open_orders_read_available: false,
      nado_current_short_eth: current_short,
      nado_flat: nado_short&.zero?,
      nado_live_enabled: bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED"),
      nado_auto_enabled: bool_env("AERODROME_NADO_AUTO_ENABLED"),
      nado_reduce_only_close_supported: false,
      nado_open_short_supported: false,
      nado_leverage_margin_known: false,
      blockers: blockers,
      warnings: [ "Nado routes are displayed for proof planning, but remain fail-closed." ],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :snapshot, :env

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def nado_short
    return nil unless snapshot

    BigDecimal(snapshot.nado_short_eth.to_s)
  rescue ArgumentError
    nil
  end
end
