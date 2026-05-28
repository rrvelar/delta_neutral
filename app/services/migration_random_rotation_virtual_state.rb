class MigrationRandomRotationVirtualState
  STATE_DIR = Rails.root.join("storage/hedge_migration_random_rotation_state")
  VERSION = 1

  def initialize(position:, state_dir: STATE_DIR, now: -> { Time.current })
    @position = position
    @state_dir = Pathname(state_dir)
    @now = now
  end

  def current
    read_state || initial_state
  end

  def update_from_decision!(decision_receipt:, daily_receipt_path: nil)
    selected_target = decision_receipt[:selected_target_venue] || decision_receipt["selected_target_venue"]
    return current if selected_target.blank?

    before = current
    state = {
      version: VERSION,
      position_id: position.id,
      production_venue: production_venue,
      virtual_current_venue: HedgeVenues.normalize(selected_target),
      previous_virtual_venue: before.fetch(:virtual_current_venue),
      last_selected_route: decision_receipt[:selected_route] || decision_receipt["selected_route"],
      last_selected_target_venue: HedgeVenues.normalize(selected_target),
      last_decision_at: now.call.utc.iso8601,
      last_receipt_path: daily_receipt_path,
      dry_run_only: true,
      orders_submitted: 0,
      signatures_created: 0
    }
    write_state(state)
    state
  end

  def reset!
    state = initial_state.merge(
      previous_virtual_venue: current[:virtual_current_venue],
      last_decision_at: now.call.utc.iso8601
    )
    write_state(state)
    state
  end

  private

  attr_reader :position, :state_dir, :now

  def initial_state
    {
      version: VERSION,
      position_id: position.id,
      production_venue: production_venue,
      virtual_current_venue: production_venue,
      previous_virtual_venue: nil,
      last_selected_route: nil,
      last_selected_target_venue: nil,
      last_decision_at: nil,
      last_receipt_path: nil,
      dry_run_only: true,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def read_state
    return nil unless File.file?(path)

    JSON.parse(File.read(path)).deep_symbolize_keys
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def write_state(state)
    FileUtils.mkdir_p(state_dir)
    File.write(path, JSON.pretty_generate(state))
    state
  end

  def path
    state_dir.join("position_#{position.id}.json")
  end

  def production_venue
    HedgeVenues.normalize(position.hedge&.execution_venue)
  end
end
