// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";
import {console} from "forge-std/console.sol";

contract BestFeesHook is BaseHook {
    using LPFeeLibrary for uint24;
    using ABDKMath64x64 for int128;

    // Constants for fee range (in basis points)
    int128 private immutable minFee; // Minimum fee (e.g., 0.3% = 3000 basis points)
    int128 private immutable maxFee; // Maximum fee (e.g., 1.0% = 10000 basis points)

    // Sigmoid parameters
    int128 private immutable alpha = 2; // Steepness of the sigmoid curve
    int128 private immutable beta = 5; // Midpoint of the sigmoid curve (volatility level)

    AggregatorV3Interface internal volatility24HFeed;
    AggregatorV3Interface internal volatility7DFeed;

    struct DataFeed {
        AggregatorV3Interface volatility24HFeed;
        AggregatorV3Interface volatility7DFeed;
        uint decimals;
    }

    mapping(PoolId poolId => DataFeed) dataFeedByPool;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // 0.5%

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(
        IPoolManager _poolManager,
        address _volatility24HFeed,
        address _volatility7DFeed,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _alpha,
        uint256 _beta
    ) BaseHook(_poolManager) {
        // Initialize parameters as 64x64 fixed-point numbers
        require(
            uint24(_minFee) >= type(uint24).min &&
                uint24(_minFee) <= type(uint24).max,
            "minFee range out of uint24 range"
        );
        require(
            uint24(_maxFee) >= type(uint24).min &&
                uint24(_maxFee) <= type(uint24).max,
            "maxFee range out of uint24 range"
        );
        minFee = ABDKMath64x64.fromUInt(_minFee); // Convert to fixed-point
        maxFee = ABDKMath64x64.fromUInt(_maxFee);
        alpha = ABDKMath64x64.fromUInt(_alpha);
        beta = ABDKMath64x64.fromUInt(_beta);

        volatility24HFeed = AggregatorV3Interface(_volatility24HFeed);
        volatility7DFeed = AggregatorV3Interface(_volatility7DFeed);
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) external pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    //TODO make sure this works properly, even without a reliable data feed
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = getFee(key.toId());
        // If we wanted to generally update LP fee for a longer-term than per-swap
        // poolManager.updateDynamicLPFee(key, fee);

        // For overriding fee per swap:
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    function getFee(PoolId poolId) public view returns (uint24) {
        if (address(dataFeedByPool[poolId].volatility24HFeed) == address(0))
            return BASE_FEE;

        DataFeed memory dataFeed = dataFeedByPool[poolId];

        int vol7d = getChainlinkVolatility7DFeedLatestAnswer(
            dataFeed.volatility7DFeed
        );
        int vol24h = getChainlinkVolatility24HFeedLatestAnswer(
            dataFeed.volatility24HFeed
        );

        return calculateDynamicFee(vol7d, vol24h);
    }

    function getChainlinkVolatility24HFeedLatestAnswer(
        AggregatorV3Interface _volatility24HFeed
    ) public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = _volatility24HFeed.latestRoundData();
        return answer;
    }

    function getChainlinkVolatility7DFeedLatestAnswer(
        AggregatorV3Interface _volatility7DFeed
    ) public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = _volatility7DFeed.latestRoundData();
        return answer;
    }

    function setDataFeed(
        PoolKey calldata _key,
        address _volatility24HFeed,
        address _volatility7DFeed,
        uint8 _decimals
    ) external {
        dataFeedByPool[_key.toId()] = DataFeed({
            volatility24HFeed: AggregatorV3Interface(_volatility24HFeed),
            volatility7DFeed: AggregatorV3Interface(_volatility7DFeed),
            decimals: _decimals
        });
    }

    function deleteDataFeed(PoolKey calldata key) external {
        require(
            address(dataFeedByPool[key.toId()].volatility24HFeed) != address(0),
            "DataFeed does not exist"
        );

        delete dataFeedByPool[key.toId()];
    }

    //TODO Check if math works out, find good a and b default values
    /**
     * @notice Calculate the dynamic fee based on volatility using a sigmoid function
     * Sigmoid Function Explanation:
     *
     * The dynamic fee is calculated using a sigmoid function, which transitions smoothly
     * between the minimum and maximum fee values based on the input volatility.
     *
     * Formula:
     * S(sigma) = minFee + (maxFee - minFee) * (1 / (1 + exp(-a * (sigma - b))))
     *
     * Where:
     * - sigma: Input volatility (e.g., 5 for 5%)
     * - minFee: Minimum fee (in basis points, e.g., 3000 = 0.3%)
     * - maxFee: Maximum fee (in basis points, e.g., 10000 = 1.0%)
     * - a: Steepness of the sigmoid curve (higher values make the transition sharper)
     * - b: Midpoint of the sigmoid curve (volatility level where the fee is halfway between minFee and maxFee)
     *
     * The sigmoid ensures the fee increases gradually with volatility, avoiding abrupt changes
     * while remaining responsive to significant market conditions.
     * @param volatility The measured volatility (as an unsigned integer percentage, e.g., 500 for 5%).
     * @return dynamicFee The computed fee in basis points.
     */
    function calculateSigmoidFee(
        int256 volatility,
        int128 alpha,
        int128 beta
    ) public view returns (uint24) {
        int128 vol = ABDKMath64x64.fromInt(volatility);
        //TODO this value should come from elsewhere
        int128 decimals = ABDKMath64x64.fromUInt(10 ** 5);
        // (volatility - b)
        int128 scaledVolatility = vol.sub(beta.mul(decimals));
        // a * (volatility - b)
        int128 exponent = alpha.mul(scaledVolatility).div(decimals);
        // exp(-a * (volatility - b))
        int128 expValue = ABDKMath64x64.exp(exponent.neg());
        int128 sigmoid = ABDKMath64x64.div(
            ABDKMath64x64.fromInt(1),
            ABDKMath64x64.fromInt(1).add(expValue)
        );
        // Map sigmoid output to the fee range: minFee + (maxFee - minFee) * sigmoid
        int128 feeRange = maxFee.sub(minFee); // (maxFee - minFee)
        int128 dynamicFee = minFee.add(feeRange.mul(sigmoid));

        // Convert dynamicFee to uint24 (basis points)
        return uint24(ABDKMath64x64.toUInt(dynamicFee));
    }

    function calculateDynamicFee(
        int256 vol7d,
        int256 vol24h
    ) public view returns (uint24) {
        // Calculate the trend
        int256 trend = vol7d - vol24h;

        // Adjust sigmoid parameters based on the trend
        int128 adjustedAlpha = alpha; // Base steepness
        int128 adjustedBeta = beta; // Base midpoint

        if (trend > 0) {
            // Decreasing volatility: Favor lower fees

            // Reduce steepness - default value = 1
            adjustedAlpha = alpha.sub(
                ABDKMath64x64.div(alpha, ABDKMath64x64.fromUInt(2))
            );

            // Raise midpoint - default value = 6
            adjustedBeta = beta.add(
                ABDKMath64x64.div(beta, ABDKMath64x64.fromUInt(5))
            );
        } else if (trend < 0) {
            // Increasing volatility: Favor higher fees

            // Increase steepness - default value = 3
            adjustedAlpha = alpha.add(
                ABDKMath64x64.div(alpha, ABDKMath64x64.fromUInt(2))
            );
            // Lower midpoint - default value = 4
            adjustedBeta = beta.sub(
                ABDKMath64x64.div(beta, ABDKMath64x64.fromUInt(5))
            );
        }

        // Calculate the sigmoid-based fee using adjusted parameters
        return calculateSigmoidFee(vol24h, adjustedAlpha, adjustedBeta);
    }
}
