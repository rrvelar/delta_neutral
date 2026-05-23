class MellowAutopilotProbesController < ApplicationController
  TX_HASH_PATTERN = /\A0x[0-9a-fA-F]{64}\z/

  def index
    @wallet_address = params[:wallet_address].to_s.strip
    @vault_address = params[:vault_address].to_s.strip
    @tx_hash = params[:tx_hash].to_s.strip
    @tx_wallet_address = params[:tx_wallet_address].to_s.strip
    @network = params[:network].to_s.presence || "base"
    @tx_network = params[:tx_network].to_s.presence || "base"
    @probe_report = if @wallet_address.present?
      MellowAutopilotPositionProbe.new(
        wallet_address: @wallet_address,
        vault_address: @vault_address.presence,
        network: @network
      ).report
    end
    @transaction_probe_report = if @tx_hash.present?
      if invalid_tx_hash?
        invalid_transaction_hash_report
      else
        AerodromeAutopilotTransactionProbe.new(tx_hash: @tx_hash, network: @tx_network, wallet_address: @tx_wallet_address.presence).report
      end
    end
  end

  def create_position
    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: mellow_position_params.fetch(:tx_hash),
      network: mellow_position_params[:network].presence || "base",
      wallet_address: mellow_position_params.fetch(:wallet_address)
    ).report

    blockers = mellow_create_blockers(report)
    if blockers.any?
      redirect_to mellow_autopilot_probe_path(tx_hash: mellow_position_params[:tx_hash], tx_wallet_address: mellow_position_params[:wallet_address]), alert: blockers.join("; ")
      return
    end

    position = nil
    ActiveRecord::Base.transaction do
      if ActiveModel::Type::Boolean.new.cast(mellow_position_params[:deactivate_existing_positions])
        Position.active_hedgeable.update_all(active: false, updated_at: Time.current)
      end

      position = create_mellow_position!(report)
    end

    redirect_to position_path(position), notice: "Mellow Autopilot position created from hedgeable probe result."
  rescue KeyError, ActiveRecord::RecordInvalid, ArgumentError => e
    redirect_to mellow_autopilot_probe_path, alert: "Create Mellow position failed: #{e.message}"
  end

  private

  def invalid_tx_hash?
    !@tx_hash.match?(TX_HASH_PATTERN)
  end

  def invalid_transaction_hash_report
    {
      database_write: false,
      external_api: false,
      network: @tx_network,
      tx_hash: @tx_hash,
      classification: "unknown",
      hedgeable: false,
      submitted_wallet: @tx_wallet_address.presence,
      detected_depositor_wallet: nil,
      pool_address: nil,
      strategy_token_ids: [],
      router_or_manager_contracts: [],
      intermediate_contracts: [],
      pool_or_gauge_contracts: [],
      user_deposit_amounts: {},
      candidate_share_tokens: [],
      strategy_contract_reads: [],
      strategy_nft_exposure: {},
      pro_rata_exposure: {},
      erc20_transfers: [],
      slipstream_nft_transfers: [],
      blockers: [ "Invalid transaction hash format." ],
      warnings: []
    }
  end

  def mellow_create_blockers(report)
    blockers = []
    blockers << "Probe result is not hedgeable." unless report[:hedgeable]
    blockers << "classification must be autopilot_shared_strategy" unless report[:classification] == "autopilot_shared_strategy"
    blockers << "submitted wallet is required" if report[:submitted_wallet].blank?
    blockers << "strategy token ID is required" if report[:strategy_token_id].blank?
    blockers << "share token is required" if report.dig(:pro_rata_exposure, :share_token).blank?
    blockers << "user WETH exposure is required" if report[:user_weth_exposure].blank?
    if Position.active_hedgeable.exists? && existing_mellow_position_for(report).nil? && !ActiveModel::Type::Boolean.new.cast(mellow_position_params[:deactivate_existing_positions])
      blockers << "Only one active hedgeable position is supported. Deactivate the existing position first or select deactivate existing."
    end
    blockers.concat(report.fetch(:blockers, []))
    blockers.uniq
  end

  def create_mellow_position!(report)
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: Current.user,
      network: Network.find_by!(name: "base"),
      address: report.fetch(:submitted_wallet)
    )
    metadata = mellow_metadata_from_report(report)
    position = existing_mellow_position_for(report)
    previous_token_id = position&.mellow_metadata_hash&.fetch("strategy_token_id", nil)
    if previous_token_id.present? && previous_token_id != metadata["strategy_token_id"]
      metadata["observed_strategy_token_id_history"] = Array(position.mellow_metadata_hash["observed_strategy_token_id_history"]) | [ previous_token_id ]
    end

    attributes = {
      dex: dex,
      wallet: wallet,
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: position&.external_id || "mellow:#{report.fetch(:strategy_token_id)}",
      pool_address: report.fetch(:strategy_pool_address),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal(report.fetch(:user_weth_exposure)),
      asset1_amount: report[:user_usdc_exposure].present? ? BigDecimal(report.fetch(:user_usdc_exposure)) : nil,
      asset0_price_usd: nil,
      asset1_price_usd: BigDecimal("1"),
      active: true,
      mellow_metadata: JSON.generate(metadata)
    }
    if position.nil? || position.entry_value_usd.nil?
      attributes[:entry_value_usd] = report[:user_total_value_usd].present? ? BigDecimal(report.fetch(:user_total_value_usd)) : nil
    end

    position ||= Current.user.positions.build
    position.update!(attributes)
    position.create_hedge!(active: true, target: BigDecimal("1.0"), tolerance: BigDecimal("0.03")) unless position.hedge
    position
  end

  def existing_mellow_position_for(report)
    exposure = report.fetch(:pro_rata_exposure)
    submitted_wallet = report.fetch(:submitted_wallet).to_s.downcase
    share_token = exposure[:share_token].to_s.downcase
    strategy_pool = exposure[:strategy_pool_address].to_s.downcase
    Current.user.positions.includes(:wallet).active.where(source: Position::SOURCE_MELLOW_AUTOPILOT).detect do |position|
      metadata = position.mellow_metadata_hash
      wallet_match = position.wallet.address.to_s.downcase == submitted_wallet || metadata["submitted_wallet"].to_s.downcase == submitted_wallet
      wallet_match &&
        metadata["share_token"].to_s.downcase == share_token &&
        (metadata["strategy_pool_address"].to_s.downcase == strategy_pool || position.pool_address.to_s.downcase == strategy_pool)
    end
  end

  def mellow_metadata_from_report(report)
    exposure = report.fetch(:pro_rata_exposure)
    {
      "tx_hash" => report[:tx_hash],
      "submitted_wallet" => report[:submitted_wallet],
      "share_token" => exposure[:share_token],
      "strategy_token_id" => exposure[:strategy_token_id],
      "strategy_pool_address" => exposure[:strategy_pool_address],
      "user_share_balance" => exposure[:user_share_balance],
      "total_shares" => exposure[:total_shares],
      "user_share_percent" => exposure[:user_share_percent],
      "strategy_token0" => report.dig(:strategy_nft_exposure, :token0_address),
      "strategy_token1" => report.dig(:strategy_nft_exposure, :token1_address),
      "strategy_total_weth" => exposure[:strategy_total_weth],
      "strategy_total_usdc" => exposure[:strategy_total_usdc],
      "user_weth_exposure" => exposure[:user_weth_exposure],
      "user_usdc_exposure" => exposure[:user_usdc_exposure],
      "user_total_value_usd" => exposure[:user_total_value_usd],
      "last_probe_confidence" => exposure[:exposure_confidence] || exposure[:confidence],
      "last_probe_at" => Time.current.iso8601,
      "hedge_ready" => true
    }
  end

  def mellow_position_params
    params.require(:mellow_position).permit(:tx_hash, :wallet_address, :network, :deactivate_existing_positions)
  end
end
