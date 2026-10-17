// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 5: THE GUT (where DIGEST and ROOTS do their work)
//
// Observed, DIGEST: the nucleus sends the buyback book here as ETH claims. Anyone may run `digest`, at most once an
//   hour per species: it buys NOOK through the species' own pool and burns every token it bought. One buyback spends
//   at most 1% of the ETH it would take to push that pool's price down 2% (a sweep sized to the pool cannot be
//   sandwiched for much). It trades like anyone: the nucleus' fees, Programmable's 0.30% included, apply.
// Observed, ROOTS: the nucleus sends the roots book here. Anyone may run `plant`, at most once every 6 hours per
//   species: it adds that ETH as liquidity just above the price (where NOOK is cheaper, about 20% of room), so it
//   buys NOOK only when NOOK falls. This contract has no function that removes liquidity: ROOTS stay forever.
// Observed: `gather` collects a ROOTS position's fees: its ETH goes back to the nucleus for NECTAR, its NOOK is burned.
// Limit, stated: these run only when someone calls them; a quiet day leaves the books waiting here.

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {INookToken} from "./Interfaces.sol";

interface INucleusForGut {
    function keyOf(uint256 s) external view returns (PoolKey memory);
    function speciesCount() external view returns (uint256);
    function creditNectar(uint256 eth) external;
}

contract Gut is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant DIGEST_GAP = 1 hours;
    uint256 public constant PLANT_GAP = 6 hours;
    uint256 public constant SWEEP_BPS = 100;
    int24 public constant SWEEP_TICKS = 198;
    int24 public constant ROOTS_SPAN = 2220; // 1.0001^2220 = 1.249: NOOK about 20% cheaper at the far edge

    IPoolManager public immutable MANAGER;
    address public immutable NUCLEUS;
    address public immutable NOOK;

    uint256 public digestBook;
    uint256 public rootsBook;
    mapping(uint256 => uint64) public lastDigest;
    mapping(uint256 => uint64) public lastPlant;
    uint256 public burnedTotal;

    struct Root {
        uint8 species;
        int24 lower;
        int24 upper;
    }

    Root[] public roots;

    uint8 internal constant DO_DIGEST = 1;
    uint8 internal constant DO_PLANT = 2;
    uint8 internal constant DO_GATHER = 3;

    event Funded(uint256 digest, uint256 roots);
    event Digested(uint256 indexed species, uint256 ethSpent, uint256 nookBurned);
    event Planted(uint256 indexed species, uint256 index, int24 lower, int24 upper, uint256 eth, uint128 liquidity);
    event Gathered(uint256 indexed index, uint256 eth, uint256 nookBurned);

    error NotNucleus();
    error NotManager();
    error TooSoon();
    error Nothing();

    constructor(IPoolManager manager, address nucleus, address nook) {
        MANAGER = manager;
        NUCLEUS = nucleus;
        NOOK = nook;
    }

    /// @notice By the nucleus, after it moved these claims here.
    function fund(uint256 dg, uint256 r) external {
        if (msg.sender != NUCLEUS) revert NotNucleus();
        digestBook += dg;
        rootsBook += r;
        emit Funded(dg, r);
    }

    // ------------------------------------------------------------------------------------------------ DIGEST

    /// @notice What a buyback in species `s` may spend right now.
    function sweepable(uint256 s) public view returns (uint256) {
        PoolKey memory key = INucleusForGut(NUCLEUS).keyOf(s);
        (uint160 sqrtP, int24 tick,,) = MANAGER.getSlot0(key.toId());
        uint128 L = MANAGER.getLiquidity(key.toId());
        if (sqrtP == 0 || L == 0) return 0;
        int24 lowTick = tick - SWEEP_TICKS < TickMath.MIN_TICK ? TickMath.MIN_TICK : tick - SWEEP_TICKS;
        uint160 low = TickMath.getSqrtPriceAtTick(lowTick);
        if (low >= sqrtP) return 0;
        // ETH that moves the price down 2% at today's liquidity
        uint256 push = FullMath.mulDiv(uint256(L) << 96, sqrtP - low, sqrtP) / low;
        uint256 cap = (push * SWEEP_BPS) / 10_000;
        return digestBook < cap ? digestBook : cap;
    }

    function digest(uint256 s) external returns (uint256 spent, uint256 burned) {
        if (block.timestamp < uint256(lastDigest[s]) + DIGEST_GAP) revert TooSoon();
        spent = sweepable(s);
        if (spent == 0) revert Nothing();
        lastDigest[s] = uint64(block.timestamp);
        digestBook -= spent;
        burned = abi.decode(MANAGER.unlock(abi.encode(DO_DIGEST, s, spent, int24(0), int24(0), uint128(0))), (uint256));
        INookToken(NOOK).burn(burned);
        burnedTotal += burned;
        emit Digested(s, spent, burned);
    }

    // ------------------------------------------------------------------------------------------------ ROOTS

    function plant(uint256 s) external returns (uint128 liquidity) {
        if (block.timestamp < uint256(lastPlant[s]) + PLANT_GAP) revert TooSoon();
        uint256 eth = rootsBook;
        if (eth == 0) revert Nothing();
        PoolKey memory key = INucleusForGut(NUCLEUS).keyOf(s);
        (, int24 tick,,) = MANAGER.getSlot0(key.toId());
        int24 sp = key.tickSpacing;
        int24 lower = (tick / sp) * sp;
        if (tick < 0 && tick % sp != 0) lower -= sp;
        lower += sp; // strictly above the price: ETH only
        int24 upper = lower + (ROOTS_SPAN / sp) * sp;
        if (upper > TickMath.maxUsableTick(sp)) revert Nothing();
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        // liquidity for `eth` of currency0 across [a, b]
        liquidity = uint128(FullMath.mulDiv(FullMath.mulDiv(eth, a, 1 << 96), b, b - a));
        if (liquidity == 0) revert Nothing();
        lastPlant[s] = uint64(block.timestamp);
        uint256 used = abi.decode(MANAGER.unlock(abi.encode(DO_PLANT, s, uint256(0), lower, upper, liquidity)), (uint256));
        rootsBook -= used;
        roots.push(Root(uint8(s), lower, upper));
        emit Planted(s, roots.length - 1, lower, upper, used, liquidity);
    }

    /// @notice Collect a ROOTS position's fees: ETH to NECTAR, NOOK burned. Anyone may call.
    function gather(uint256 i) external returns (uint256 eth, uint256 nook) {
        Root memory r = roots[i];
        (eth, nook) = abi.decode(MANAGER.unlock(abi.encode(DO_GATHER, uint256(r.species), uint256(0), r.lower, r.upper, uint128(0))), (uint256, uint256));
        if (eth != 0) INucleusForGut(NUCLEUS).creditNectar(eth);
        if (nook != 0) {
            INookToken(NOOK).burn(nook);
            burnedTotal += nook;
        }
        emit Gathered(i, eth, nook);
    }

    function rootCount() external view returns (uint256) {
        return roots.length;
    }

    // ------------------------------------------------------------------------------------------------ the manager

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert NotManager();
        (uint8 op, uint256 s, uint256 amount, int24 lower, int24 upper, uint128 liquidity) =
            abi.decode(data, (uint8, uint256, uint256, int24, int24, uint128));
        PoolKey memory key = INucleusForGut(NUCLEUS).keyOf(s);
        if (op == DO_DIGEST) {
            BalanceDelta d = MANAGER.swap(key, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1), "");
            uint256 paid = uint256(-int256(d.amount0()));
            uint256 got = uint256(int256(d.amount1()));
            MANAGER.burn(address(this), 0, paid); // pay with the buyback claims
            MANAGER.take(key.currency1, address(this), got);
            return abi.encode(got);
        }
        if (op == DO_PLANT) {
            (BalanceDelta d,) = MANAGER.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
            uint256 used = uint256(-int256(d.amount0()));
            MANAGER.burn(address(this), 0, used);
            return abi.encode(used);
        }
        // DO_GATHER: a zero change collects the fees owed to this position
        (BalanceDelta f,) = MANAGER.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 0, 0), "");
        uint256 eth = uint256(int256(f.amount0()));
        uint256 nook = uint256(int256(f.amount1()));
        if (eth != 0) MANAGER.mint(NUCLEUS, 0, eth); // as claims, straight to the nucleus
        if (nook != 0) MANAGER.take(key.currency1, address(this), nook);
        return abi.encode(eth, nook);
    }
}
