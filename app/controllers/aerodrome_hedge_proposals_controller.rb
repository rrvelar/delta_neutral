class AerodromeHedgeProposalsController < ApplicationController
  def create
    build_proposal
  end

  def regenerate
    build_proposal
  end

  def mark_reviewed
    proposal = find_proposal
    safety = AerodromeHedgeProposalSafety.new.evaluate(proposal)
    if safety.blocked
      redirect_to position_path(proposal.position), alert: "Blocked manual hedge proposals cannot be marked reviewed. No orders were placed."
      return
    end

    proposal.mark_reviewed!

    redirect_to position_path(proposal.position), notice: "Manual hedge proposal marked reviewed. No orders were placed."
  end

  def reject
    proposal = find_proposal
    proposal.reject!(notes: params[:notes])

    redirect_to position_path(proposal.position), notice: "Manual hedge proposal rejected. No orders were placed."
  end

  private

  def build_proposal
    position = find_position
    result = AerodromeHedgeProposalBuilder.new.call(position)

    if result.created
      redirect_to position_path(position), notice: "Manual hedge proposal generated. Execution remains disabled."
    else
      redirect_to position_path(position), alert: "Manual hedge proposal unavailable: #{result.reason}"
    end
  end

  def find_position
    Current.user.positions.includes(:dex).find(params[:position_id])
  end

  def find_proposal
    AerodromeHedgeProposal.joins(position: :user)
      .where(positions: { user_id: Current.user.id })
      .find(params[:id])
  end
end
