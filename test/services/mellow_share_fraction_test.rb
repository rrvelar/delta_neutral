require "test_helper"

class MellowShareFractionTest < ActiveSupport::TestCase
  test "interprets sub-one user_share_percent as percent when exposures agree" do
    result = MellowShareFraction.resolve(
      "0.156",
      "user_weth_exposure" => "1.56",
      "strategy_total_weth" => "1000"
    )

    assert_equal "percent", result.interpretation
    assert_equal BigDecimal("0.00156"), result.fraction
  end

  test "keeps sub-one value as fraction when exposures agree" do
    result = MellowShareFraction.resolve(
      "0.00156",
      "user_weth_exposure" => "1.56",
      "strategy_total_weth" => "1000"
    )

    assert_equal "fraction", result.interpretation
    assert_equal BigDecimal("0.00156"), result.fraction
  end
end
