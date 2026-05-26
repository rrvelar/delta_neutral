namespace :extended do
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
    hedge = Struct.new(:id, :target, keyword_init: true).new(id: ENV["HEDGE_ID"] || 3, target: BigDecimal("1.0"))
    Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
      def active? = true
      def mellow_autopilot? = true
      def hedge_ready? = true
      def mellow_weth_exposure = BigDecimal("0.5")
    end.new(id: ENV["position_id"] || ENV["POSITION_ID"] || 3, hedge: hedge, asset0_price_usd: BigDecimal("2100"))
  end
end
