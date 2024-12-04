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

contract TestBestFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    BestFeesHook hook;
    MockV3Aggregator public mockV3Aggregator24H;
    MockV3Aggregator public mockV3Aggregator7D;

    uint8 public constant DECIMALS = 5;
    int256 public constant INITIAL_ANSWER_24H = 35 * 10 ** 4; //50%
    int256 public constant INITIAL_ANSWER_7D = 1 * 10 ** 1; //100%

    int256 public constant MIN_FEE = 3000;
    int256 public constant MAX_FEE = 10000;
    int256 public constant ALPHA = 2; // steepness
    int256 public constant BETA = 5; // midpoint

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

    function test_ChainlinkVolatilityFeed() public {
        int value = hook.getChainlinkVolatility24HFeedLatestAnswer();

        console.log("value", value);
    }

    function test_GetFee() public {
        mockV3Aggregator24H.updateAnswer(INITIAL_ANSWER_24H);
        uint24 value = hook.getFee();

        console.log("value", value);
    }
}
