namespace :mellow do
  desc "Read-only Mellow rewards/fees route diagnostics"
  task rewards_route_check: :environment do
    position_id = ENV["POSITION_ID"].presence
    unless position_id
      puts "POSITION_ID is required"
      next
    end

    position = Position.includes(:wallet).find_by(id: position_id)
    unless position
      puts "position_id: #{position_id}"
      puts "status: unavailable"
      puts "stop_reason: position not found"
      next
    end

    token = AerodromePositionTokenResolver.resolve(position)
    discovery = MellowRewardsRouteDiscovery.new(position: position).report
    rewards = AerodromeRewardsCheck.new(position: position).report
    fees = AerodromeFeesCheck.new(position: position).report

    puts "position_id: #{position.id}"
    puts "source: #{position.source}"
    puts "synthetic_external_id: #{position.external_id}"
    puts "resolved_numeric_strategy_token_id: #{token.token_id || 'unavailable'}"
    puts "ownerOf: #{discovery.owner_address || 'unavailable'}"
    puts "discovered_gauge: #{discovery.gauge_address || 'unavailable'}"
    puts "strategy_token_staked_in_gauge: #{discovery.strategy_token_staked_in_gauge.nil? ? 'unavailable' : discovery.strategy_token_staked_in_gauge}"
    puts "direct_depositor_staked: #{discovery.direct_depositor_staked.nil? ? 'unavailable' : discovery.direct_depositor_staked}"
    puts "gauge_stake_status: #{discovery.gauge_staked.nil? ? 'unavailable' : discovery.gauge_staked}"
    puts "reward_read_method_attempted: #{discovery.reward_read_method || 'unavailable'}"
    puts "reward_token_address: #{discovery.reward_token_address || rewards[:reward_token_address] || 'unavailable'}"
    puts "reward_read_reverted: #{discovery.reward_read_error.present?}"
    puts "reward_account_used: #{discovery.reward_account_address || rewards[:reward_account_address] || 'unavailable'}"
    puts "raw_gauge_earned: #{discovery.raw_gauge_earned || rewards[:raw_gauge_earned] || 'unavailable'}"
    puts "reward_token_decimals: #{discovery.reward_token_decimals || rewards[:reward_token_decimals] || 'unavailable'}"
    puts "raw_aero_amount_before_pro_rata: #{discovery.raw_aero_amount_before_pro_rata&.to_s('F') || rewards[:raw_aero_amount_before_pro_rata] || 'unavailable'}"
    puts "pro_rata_share_raw: #{discovery.pro_rata_share_raw&.to_s('F') || rewards[:pro_rata_share_raw] || 'unavailable'}"
    puts "pro_rata_share_interpretation: #{discovery.pro_rata_share_interpretation || rewards[:pro_rata_share_interpretation] || 'unavailable'}"
    puts "exposure_derived_share: #{discovery.exposure_derived_share&.to_s('F') || rewards[:exposure_derived_share] || 'unavailable'}"
    puts "pro_rata_fraction_used: #{discovery.pro_rata_fraction_used&.to_s('F') || rewards[:pro_rata_fraction_used] || 'unavailable'}"
    puts "reward_scope: #{discovery.reward_scope || rewards[:reward_scope] || 'unavailable'}"
    puts "source_confidence: #{discovery.source_confidence || rewards[:source_confidence] || 'unavailable'}"
    puts "final_computed_user_aero_amount: #{rewards[:claimable_aero] || 'unavailable'}"
    puts "aero_usd_price: #{rewards[:aero_usd_price] || 'unavailable'}"
    puts "final_computed_usd: #{rewards[:claimable_aero_usd] || 'unavailable'}"
    if ENV["EXPECTED_AERO"].present?
      puts "expected_aero: #{ENV['EXPECTED_AERO']}"
      puts "expected_aero_delta: #{rewards[:expected_aero_delta] || 'unavailable'}"
      puts "expected_aero_delta_percent: #{rewards[:expected_aero_delta_percent] || 'unavailable'}"
    end
    puts "reward_route_status: #{rewards[:value_state] || discovery.reward_route_status}"
    puts "reward_stop_reason: #{rewards[:stop_reason] || discovery.stop_reason || 'none'}"
    puts "fee_route_status: #{fees[:value_state] || discovery.fee_route_status}"
    puts "fee_stop_reason: #{fees[:stop_reason] || 'none'}"
    puts "pro_rata_share: #{token.pro_rata_share&.to_s('F') || 'unavailable'}"
    puts "warnings:"
    (Array(discovery.warnings) + Array(rewards[:warnings]) + Array(fees[:warnings])).uniq.each do |warning|
      puts "- #{warning}"
    end
    puts "transactions: none"
    puts "signatures: none"
  end
end
