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
    puts "gauge_stake_status: #{discovery.gauge_staked.nil? ? 'unavailable' : discovery.gauge_staked}"
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
