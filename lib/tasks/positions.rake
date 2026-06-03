namespace :positions do
  def position_id_from_env
    ENV["position_id"].presence || ENV["POSITION_ID"].presence
  end

  def maintenance_position
    id = position_id_from_env
    abort("position_id is required") if id.blank?

    Position.includes(:hedge, :position_dashboard_snapshot).find(id)
  end

  desc "List positions and hedge state without live exchange actions"
  task list: :environment do
    rows = Position.includes(:hedge).order(:id).map do |position|
      {
        id: position.id,
        active: position.active?,
        source: position.position_source,
        external_id: position.external_id,
        wallet_id: position.wallet_id,
        pool_address: position.pool_address,
        asset0_amount: position.asset0_amount&.to_s("F"),
        asset1_amount: position.asset1_amount&.to_s("F"),
        hedge_venue: position.hedge&.execution_venue,
        hedge_active: position.hedge&.active?,
        orders_submitted: 0,
        signatures_created: 0
      }
    end
    puts JSON.pretty_generate(action: "positions_list", positions: rows, orders_submitted: 0, signatures_created: 0)
  end

  desc "Activate one position and deactivate other positions for the same user"
  task activate: :environment do
    position = maintenance_position
    PositionProductionState.new(position).activate!
    DashboardSnapshotJob.perform_later(position.id, force: true) if position.dex.name == "aerodrome_slipstream"
    puts JSON.pretty_generate(
      action: "positions_activate",
      position_id: position.id,
      active: position.reload.active?,
      hedge_active: position.hedge&.active?,
      hedge_venue: position.hedge&.execution_venue,
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  desc "Archive one position and deactivate its hedge without live exchange actions"
  task archive: :environment do
    position = maintenance_position
    ok, blockers = PositionProductionState.new(position).archive!
    puts JSON.pretty_generate(
      action: "positions_archive",
      position_id: position.id,
      status: ok ? "archived" : "blocked",
      blockers: blockers,
      active: position.reload.active?,
      hedge_active: position.hedge&.active?,
      warning: "Archives only the app record; it does not close the on-chain LP or perps.",
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  desc "Find/archive duplicate position records by user_id + wallet_id + external_id + pool_address"
  task dedupe: :environment do
    dry_run = ENV["dry_run"].blank? || ActiveModel::Type::Boolean.new.cast(ENV["dry_run"])
    confirmation = ENV["confirmation"].to_s
    groups = PositionProductionState.duplicates

    applied = []
    blockers = []
    if !dry_run
      if confirmation != PositionProductionState::ARCHIVE_CONFIRMATION
        blockers << "confirmation must equal #{PositionProductionState::ARCHIVE_CONFIRMATION}"
      else
        applied = PositionProductionState.archive_duplicates!
      end
    end

    puts JSON.pretty_generate(
      action: "positions_dedupe",
      dry_run: dry_run,
      duplicate_groups: groups.map { |group| duplicate_group_payload(group) },
      applied: applied,
      blockers: blockers,
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def duplicate_group_payload(group)
    {
      key: group.fetch(:key),
      canonical_position_id: group.fetch(:canonical).id,
      duplicate_position_ids: group.fetch(:duplicates).map(&:id),
      recommendation: "Archive inactive duplicate records; never delete active positions automatically."
    }
  end
end
