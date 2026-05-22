class MellowAutopilotProbesController < ApplicationController
  def index
    @wallet_address = params[:wallet_address].to_s.strip
    @vault_address = params[:vault_address].to_s.strip
    @network = params[:network].presence || "base"
    @probe_report = if @wallet_address.present?
      MellowAutopilotPositionProbe.new(
        wallet_address: @wallet_address,
        vault_address: @vault_address.presence,
        network: @network
      ).report
    end
  end
end
