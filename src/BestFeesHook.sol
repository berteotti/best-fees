// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract BestFeesHook is BaseHook {
    using LPFeeLibrary for uint24;
    using ABDKMath64x64 for int128;

    // Constants for fee range (in basis points)
    int128 private immutable minFee; // Minimum fee (e.g., 0.3% = 3000 basis points)
    int128 private immutable maxFee; // Maximum fee (e.g., 1.0% = 10000 basis points)

    // Sigmoid parameters
    int128 private immutable a; // Steepness of the sigmoid curve
    int128 private immutable b; // Midpoint of the sigmoid curve (volatility level)

    AggregatorV3Interface internal volatility24HFeed;
    AggregatorV3Interface internal volatility7DFeed;

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
        uint256 _a,
        uint256 _b
    ) BaseHook(_poolManager) {
        // Initialize parameters as 64x64 fixed-point numbers
        minFee = ABDKMath64x64.fromUInt(_minFee); // Convert to fixed-point
        maxFee = ABDKMath64x64.fromUInt(_maxFee);
        a = ABDKMath64x64.fromUInt(_a);
        b = ABDKMath64x64.fromUInt(_b);

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
                afterSwap: true,
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

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = getFee();
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

    function getFee() internal pure returns (uint24) {
        return BASE_FEE;
    }

    function getChainlinkVolatility24HFeedLatestAnswer()
        public
        view
        returns (int)
    {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = volatility24HFeed.latestRoundData();
        return answer;
    }

    function getChainlinkVolatility7DFeedLatestAnswer()
        public
        view
        returns (int)
    {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = volatility7DFeed.latestRoundData();
        return answer;
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
    function calculateDynamicFee(
        uint256 volatility
    ) public view returns (uint256) {
        // Convert volatility to 64x64 fixed-point
        int128 vol = ABDKMath64x64.fromUInt(volatility);

        // Sigmoid function: 1 / (1 + exp(-a * (vol - b)))
        int128 scaledVolatility = vol.sub(b); // (volatility - b)
        int128 exponent = a.mul(scaledVolatility); // a * (volatility - b)
        int128 expValue = ABDKMath64x64.exp(exponent.neg()); // exp(-a * (volatility - b))
        int128 sigmoid = ABDKMath64x64.div(
            ABDKMath64x64.fromInt(1),
            ABDKMath64x64.fromInt(1).add(expValue)
        );

        // Map sigmoid output to the fee range: minFee + (maxFee - minFee) * sigmoid
        int128 feeRange = maxFee.sub(minFee); // (maxFee - minFee)
        int128 dynamicFee = minFee.add(feeRange.mul(sigmoid));

        // Convert dynamicFee to a standard uint256 (basis points)
        return ABDKMath64x64.toUInt(dynamicFee);
    }
}
