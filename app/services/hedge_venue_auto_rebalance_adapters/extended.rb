module HedgeVenueAutoRebalanceAdapters
  class Extended
    def initialize(env: ENV, runner: ExtendedAutoRebalanceOnce.new(env: env))
      @runner = runner
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:, one_shot: true, mode: nil, max_size_eth: nil, **)
      args = { position: position, dry_run: dry_run || !live, max_slippage: max_slippage, one_shot: one_shot }
      args[:confirmation] = confirmation if confirmation.present?
      args[:mode] = mode if mode.present?
      args[:max_size_eth] = max_size_eth if max_size_eth.present?
      @runner.run(**args)
    end
  end
end
