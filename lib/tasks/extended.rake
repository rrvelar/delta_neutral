namespace :extended do
  desc "Read-only reconciliation for pending Extended ShortRebalance records"
  task reconcile_pending_rebalances: :environment do
    scope = ShortRebalance.where(venue: "extended", status: ShortRebalance::STATUS_PENDING)
    scope = scope.where(hedge_id: ENV["HEDGE_ID"]) if ENV["HEDGE_ID"].present?
    reconciler = ExtendedPendingRebalanceReconciler.new
    results = scope.order(:rebalanced_at, :id).map do |rebalance|
      reconciled = reconciler.reconcile(rebalance)
      {
        id: rebalance.id,
        hedge_id: rebalance.hedge_id,
        status: rebalance.reload.status,
        reconciled: reconciled.present? && rebalance.status == ShortRebalance::STATUS_SUCCESS
      }
    end

    puts JSON.pretty_generate(
      venue: "extended",
      checked: results.size,
      results: results,
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  desc "Controlled Extended mainnet lifecycle check; dry-run by default and live remains fail-closed"
  task mainnet_lifecycle_check: :environment do
    mode = (ENV["mode"] || ENV["MODE"] || "open_only").to_s.downcase
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    size_eth = BigDecimal((ENV["size_eth"] || ENV["SIZE_ETH"] || "0.01").to_s)
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    position = extended_probe_position
    env = extended_probe_env
    venue = HedgeVenues::Extended.new(env: env)
    service = ExtendedMainnetLifecycleCheck.new(env: env, venue: venue)

    result = service.run(
      position: position,
      mode: mode,
      size_eth: size_eth,
      confirmation: confirmation,
      dry_run: dry_run,
      max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01"
    )

    receipt_path = Rails.root.join("storage", "extended_mainnet_live_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt)) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "submitted_but_readback_pending", "blocked_before_submit" ]
    abort("Extended mainnet lifecycle check did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  desc "Controlled Extended leverage update; dry-run by default"
  task set_leverage: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    market = ENV["market"] || ENV["MARKET"] || ENV["EXTENDED_MARKET_SYMBOL"] || "ETH-USD"
    leverage = ENV["leverage"] || ENV["LEVERAGE"] || ENV["EXTENDED_REQUIRED_LEVERAGE"] || "1"
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    env = extended_probe_env
    venue = HedgeVenues::Extended.new(env: env)
    result = ExtendedSetLeverageCheck.new(env: env, venue: venue).run(
      market: market,
      leverage: leverage,
      confirmation: confirmation,
      dry_run: dry_run
    )

    receipt_path = Rails.root.join("storage", "extended_leverage_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt)) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "patch_submitted_but_readback_unconfirmed", "blocked_before_patch" ]
    abort("Extended set leverage check did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  desc "Controlled one-shot Extended auto rebalance; dry-run by default"
  task auto_rebalance_once: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    mode = ENV["mode"] || ENV["MODE"]
    probe = ActiveModel::Type::Boolean.new.cast(ENV["probe"] || ENV["PROBE"])
    max_size_eth = ENV["max_size_eth"] || ENV["MAX_SIZE_ETH"] || ENV["size_eth"] || ENV["SIZE_ETH"]
    position = extended_probe_position
    env = extended_probe_env
    result = ExtendedAutoRebalanceOnce.new(env: env).run(
      position: position,
      confirmation: confirmation,
      dry_run: dry_run,
      max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
      mode: mode,
      probe: probe,
      max_size_eth: max_size_eth
    )

    receipt_path = Rails.root.join("storage", "extended_auto_rebalance_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt.merge(receipt_path: receipt_path.to_s))) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "no_op", "submitted_but_readback_pending", "blocked_before_submit" ]
    abort("Extended one-shot auto rebalance did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  desc "Read-only Extended continuous auto readiness check"
  task auto_readiness: :environment do
    position = extended_probe_position
    result = HedgeVenueAutoReadiness.new(
      env: extended_probe_env,
      adapters: { "extended" => HedgeVenueAutoAdapters::Extended.new(env: extended_probe_env) }
    ).report(position: position)

    puts JSON.pretty_generate(result)
    abort("Extended continuous auto readiness blocked: #{result.fetch(:blockers).join('; ')}") if position.respond_to?(:persisted?) && position.persisted? && !result.fetch(:continuous_auto_ready)
  end

  desc "Stepwise Ethereal to Extended migration; dry-run by default"
  task migration_step: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    position = extended_probe_position
    result = ExtendedMigrationStep.new(env: extended_probe_env).run(
      position: position,
      dry_run: dry_run,
      step_size_eth: ENV["step_size_eth"] || ENV["STEP_SIZE_ETH"] || "0.01",
      confirmation: ENV["confirmation"] || ENV["CONFIRMATION"],
      max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01"
    )

    receipt_path = Rails.root.join("storage", "extended_migration_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt.merge(receipt_path: receipt_path.to_s))) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "blocked_before_submit", "extended_leg_not_confirmed", "partial_migration_manual_action_required", "combined_outside_tolerance_manual_action_required" ]
    abort("Extended migration step did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  desc "Fast full Ethereal to Extended migration; dry-run by default"
  task migration_full: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    position = extended_probe_position
    result = ExtendedMigrationFull.new(env: extended_probe_env).run(
      position: position,
      dry_run: dry_run,
      sequence: ENV["sequence"] || ENV["SEQUENCE"] || "extended_first",
      confirmation: ENV["confirmation"] || ENV["CONFIRMATION"],
      max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01"
    )

    receipt_path = Rails.root.join("storage", "extended_migration_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt.merge(receipt_path: receipt_path.to_s))) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "blocked_before_submit", "blocked_or_extended_not_confirmed", "partial_migration_manual_action_required", "combined_outside_tolerance_manual_action_required" ]
    abort("Extended full migration did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  desc "Finalize Ethereal to Extended migration after readback confirms final state; dry-run by default"
  task migration_finalize: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    position = extended_probe_position
    result = ExtendedMigrationFinalize.new(env: extended_probe_env).run(
      position: position,
      dry_run: dry_run,
      confirmation: ENV["confirmation"] || ENV["CONFIRMATION"]
    )

    receipt_path = Rails.root.join("storage", "extended_migration_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt.merge(receipt_path: receipt_path.to_s))) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    allowed_statuses = dry_run ? [ "dry_run" ] : [ "success", "blocked_before_finalize" ]
    abort("Extended migration finalize did not pass: #{result.status}") unless result.status.in?(allowed_statuses)
  end

  def extended_probe_position
    return extended_mock_position if ActiveModel::Type::Boolean.new.cast(ENV["MOCK_EXTENDED_READBACK"])

    Position.find(ENV["position_id"] || ENV["POSITION_ID"] || 3)
  rescue ActiveRecord::RecordNotFound
    raise unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))

    extended_mock_position
  end

  def extended_probe_env
    return ENV unless ActiveModel::Type::Boolean.new.cast(ENV["MOCK_EXTENDED_READBACK"])

    ENV.to_h.merge(
      "EXTENDED_API_BASE_URL" => "https://api.starknet.extended.exchange/api/v1",
      "EXTENDED_API_KEY" => "mock-redacted",
      "EXTENDED_ACCOUNT_ID" => "mock-account",
      "EXTENDED_VAULT_NUMBER" => "1001",
      "EXTENDED_CLIENT_ID" => "mock-client",
      "EXTENDED_STARK_PUBLIC_KEY" => "0xabc",
      "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
      "EXTENDED_SIZE_INCREMENT" => "0.0001",
      "EXTENDED_PRICE_INCREMENT" => "0.1"
    )
  end

  def extended_mock_position
    hedge = Struct.new(:id, :target, :tolerance, :execution_venue, keyword_init: true).new(
      id: ENV["HEDGE_ID"] || 3,
      target: BigDecimal("1.0"),
      tolerance: BigDecimal("0.03"),
      execution_venue: "extended"
    )
    Struct.new(:id, :hedge, :asset0_amount, :asset1_amount, :asset0_price_usd, keyword_init: true) do
      def active? = true
      def persisted? = false
      def mellow_autopilot? = true
      def hedge_ready? = true
      def position_source = Position::SOURCE_MELLOW_AUTOPILOT
      def reload = self
      def mellow_metadata_hash
        {
          "hedge_ready" => true,
          "last_probe_confidence" => "current_share_token_resolver_high",
          "exposure_source" => "current_share_token_resolver",
          "last_current_exposure_at" => Time.current.iso8601,
          "user_weth_exposure" => asset0_amount.to_s("F"),
          "user_usdc_exposure" => asset1_amount.to_s("F")
        }
      end
      def mellow_current_value_usd = BigDecimal("1290")
      def entry_value_usd = BigDecimal("1290")
      def mellow_weth_exposure = asset0_amount
      def mellow_usdc_exposure = asset1_amount
    end.new(id: ENV["position_id"] || ENV["POSITION_ID"] || 3, hedge: hedge, asset0_amount: BigDecimal("0.5"), asset1_amount: BigDecimal("240"), asset0_price_usd: BigDecimal("2100"))
  end
end
