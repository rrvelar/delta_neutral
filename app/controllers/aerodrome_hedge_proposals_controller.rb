class AerodromeHedgeProposalsController < ApplicationController
  def create
    position = find_position
    result = AerodromeHedgeProposalBuilder.new.call(position)

    if result.created
      redirect_to position_path(position), notice: "Manual hedge proposal generated. Execution remains disabled."
    else
      redirect_to position_path(position), alert: "Manual hedge proposal unavailable: #{result.reason}"
    end
  end

  def mark_reviewed
    proposal = find_proposal
    proposal.mark_reviewed!

    redirect_to position_path(proposal.position), notice: "Manual hedge proposal marked reviewed. No orders were placed."
  end

  def reject
    proposal = find_proposal
    proposal.reject!(notes: params[:notes])

    redirect_to position_path(proposal.position), notice: "Manual hedge proposal rejected. No orders were placed."
  end

  private

  def find_position
    Current.user.positions.includes(:dex).find(params[:position_id])
  end

  def find_proposal
    AerodromeHedgeProposal.joins(position: :user)
      .where(positions: { user_id: Current.user.id })
      .find(params[:id])
  end
end
