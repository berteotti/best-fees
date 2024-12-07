// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {BestFeesHook} from "../src/BestFeesHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract TestBestFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    BestFeesHook hook;
    MockV3Aggregator public mockV3Aggregator24H;
    MockV3Aggregator public mockV3Aggregator7D;

    uint8 public constant DECIMALS = 5;
    int256 public constant INITIAL_ANSWER_24H = 4 * int(10 ** DECIMALS); // 4%
    int256 public constant INITIAL_ANSWER_7D = 1 * int(10 ** DECIMALS); // 10%

    uint24 public constant MIN_FEE = 3000;
    uint24 public constant MAX_FEE = 10000;
    int128 public constant ALPHA = 2; // steepness
    int128 public constant BETA = 5; // midpoint

    function setUp() public {
        mockV3Aggregator24H = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_24H
        );
        mockV3Aggregator7D = new MockV3Aggregator(DECIMALS, INITIAL_ANSWER_7D);

        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );

        // Set gas price = 10 gwei and deploy our hook
        vm.txGasPrice(10 gwei);
        deployCodeTo(
            "BestFeesHook",
            abi.encode(
                manager,
                mockV3Aggregator24H,
                mockV3Aggregator7D,
                MIN_FEE,
                MAX_FEE,
                ALPHA,
                BETA
            ),
            hookAddress
        );
        hook = BestFeesHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );

        hook.setDataFeed(
            key,
            address(mockV3Aggregator24H),
            address(mockV3Aggregator7D),
            DECIMALS
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_ChainlinkVolatilityFeed() public view {
        // Get the current volatility from the mock feed
        int256 volatility24H = hook.getChainlinkVolatility24HFeedLatestAnswer(
            AggregatorV3Interface(address(mockV3Aggregator24H))
        );
        int256 volatility7D = hook.getChainlinkVolatility7DFeedLatestAnswer(
            AggregatorV3Interface(address(mockV3Aggregator7D))
        );

        // Assert that the volatility values match the INITIAL_ANSWER values
        assertEq(volatility24H, INITIAL_ANSWER_24H);
        assertEq(volatility7D, INITIAL_ANSWER_7D);
    }

    function test_GetFee() public {
        mockV3Aggregator24H.updateAnswer(INITIAL_ANSWER_24H);
        uint24 value = hook.getFee(key.toId());

        console.log("get fee:", value);
    }

    function test_FeeRangeRespected() public {
        // Test minimum fee
        mockV3Aggregator24H.updateAnswer(0);
        uint24 minFeeCase = hook.getFee(key.toId());
        assertEq(
            minFeeCase,
            MIN_FEE,
            "Fee should be at minimum when volatility is 0"
        );

        // Test maximum fee
        mockV3Aggregator24H.updateAnswer(int256(100) * int256(10 ** DECIMALS)); // 100% volatility
        uint24 maxFeeCase = hook.getFee(key.toId());
        assertEq(
            maxFeeCase,
            MAX_FEE,
            "Fee should be at maximum when volatility is very high"
        );
    }

    function test_FeeResponseToVolatility() public {
        // Test several volatility points
        int256[] memory volatilities = new int256[](4);
        volatilities[0] = int256(1) * int256(10 ** DECIMALS); // 1%
        volatilities[1] = int256(5) * int256(10 ** DECIMALS); // 5%
        volatilities[2] = int256(10) * int256(10 ** DECIMALS); // 10%
        volatilities[3] = int256(20) * int256(10 ** DECIMALS); // 20%

        uint24[] memory fees = new uint24[](4);

        for (uint i = 0; i < volatilities.length; i++) {
            mockV3Aggregator24H.updateAnswer(volatilities[i]);
            fees[i] = hook.getFee(key.toId());

            if (i > 0) {
                assertTrue(
                    fees[i] >= fees[i - 1],
                    "Fees should increase with volatility"
                );
            }
        }
    }

    function test_InvalidPoolInitialization() public {
        // Try to initialize a pool without setting data feed
        PoolKey memory newKey = PoolKey({
            currency0: Currency(currency0),
            currency1: Currency(currency1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(); // Should revert if trying to initialize without setting data feed
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    function test_DataFeedUpdate() public {
        // Deploy new mock aggregators
        MockV3Aggregator newAggregator24H = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_24H
        );
        MockV3Aggregator newAggregator7D = new MockV3Aggregator(
            DECIMALS,
            INITIAL_ANSWER_7D
        );

        // Update data feed
        hook.setDataFeed(
            key,
            address(newAggregator24H),
            address(newAggregator7D),
            DECIMALS
        );

        // Verify the new feed is being used
        newAggregator24H.updateAnswer(int256(5) * int256(10 ** DECIMALS)); // 5%
        uint24 newFee = hook.getFee(key.toId());
        assertTrue(newFee != 0, "Fee should be calculated with new feed");
    }

    function test_SwapWithDynamicFees() public {
        // Set initial volatility
        mockV3Aggregator24H.updateAnswer(int256(5) * int256(10 ** DECIMALS)); // 5%

        // Perform a swap
        bool zeroForOne = true;
        int256 amountSpecified = 1e18;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: true, settleUsingBurn: false});

        // Perform swap using the swap router which handles locking internally
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }

    function test_RevertOnInvalidFeeBounds() public {
        // Deploy hook with invalid fee bounds (min > max)
        address hookAddress = address(
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)
        );

        vm.expectRevert(); // Should revert on invalid fee bounds
        deployCodeTo(
            "BestFeesHook",
            abi.encode(
                manager,
                mockV3Aggregator24H,
                mockV3Aggregator7D,
                MAX_FEE, // Using max as min
                MIN_FEE, // Using min as max
                ALPHA,
                BETA
            ),
            hookAddress
        );
    }
}
