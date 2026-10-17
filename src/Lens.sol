// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 3: THE LENS (readings of the wild)
//
// Observed: the lens keeps up to 192 pools in view, each one a pool a scout listed in the field guide, with native
//   ETH as its first currency (only those can be measured in ETH without trusting a price).
// Observed, a sample: anyone may sample tracked pools, each at most once an hour, through PoolManager.extsload only
//   (no other hook's code ever runs). It reads the pool's ETH-side fee growth and liquidity, and every 6 hours the
//   real ETH resting within 2% above the price (a walk over at most 16 initialized ticks; beyond that, nothing more
//   is counted). Token-side fees are ignored: converting them would need a price the sampler could move.
// Observed, life: the ETH fee rate, as a mean over a day and over a week. A pool's say in the brain is
//   sqrt(rate x depth), capped at 5% of all pools' uncapped say, so neither a wash trader without capital nor one
//   giant pool decides alone. With no measured life at all, the brain reads no signal (never "everything is failing"). Measured (econ/brain.cjs): moving the rarest family two levels took fake pools holding about
//   30 ETH of depth.
// Observed: a fixed bounty per pool sampled, paid from the observers' ETH claims the nucleus sends here, never more
//   than the claims on hand. Gas is not repaid; the bounty does not grow with gas.
// Observed: the Hall of Hooks (the ten best ratings) and a paper index of those hooks, re-weighted every season and
//   marked from pool prices. Paper only: this contract never buys anything.
// Limit, stated: fees can be inflated for free by a pool's own LP (trading against itself, proved in
//   test/WashProbe.t.sol, or donating to itself and collecting it back). So the fee rate counted is capped at 5% of
//   the pool's real ETH depth a day, depth may at most double between readings 6 hours apart, and nothing is sampled
//   while the PoolManager is mid-transaction (no flash liquidity). Influence therefore costs ETH actually resting in
//   a pool at sampling times; a holder of a lot of ETH can still lend it to a pool for a while. Nothing that pays money
//   depends on a rating.

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

interface IGuideForLens {
    function entryForLens(uint32 ref) external view returns (bytes32 poolId, int24 spacing, uint8 mask, uint8 originality, uint8 complexity);
}

contract Lens is IUnlockCallback {
    uint256 public constant MAX_TRACKED = 192;
    uint256 public constant SAMPLE_GAP = 1 hours;
    uint256 public constant DEPTH_GAP = 6 hours;
    int24 public constant DEPTH_TICKS = 198; // 1.0001^198 = 1.0200
    uint256 public constant MAX_WALK = 16;
    uint256 public constant CAP_BPS = 500;
    uint256 public constant BOUNTY = 0.00002 ether;
    uint256 public constant SHORT = 1 days;
    uint256 public constant LONG = 7 days;
    uint256 public constant EVICT_SCAN = 16;
    uint256 public constant TENURE = 3 days;
    uint256 public constant RATE_CAP_BPS = 500; // fees counted: at most 5% of the pool's real depth a day
    uint256 internal constant MAX_SAY = 1 << 56; // per pool, so 192 pools' sums fit the packed 64-bit fields
    uint256 internal constant TERM_CAP = 1 << 120; // a paper position's marked value never above this (no overflow)
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant POOLS_SLOT = 6;

    IPoolManager public immutable MANAGER;
    address public immutable SPROUT;
    address public guide;
    address public helix;
    bool public bound;

    // five storage slots per pool; says in units of SAY_UNIT, so four fit in one slot
    struct Tracked {
        bytes32 poolId;
        uint32 ref;
        uint40 lastAt;
        uint40 depthAt;
        uint40 since;
        uint8 mask;
        int24 spacing;
        uint8 originality; // from the field guide at listing; 0 once contested
        uint8 complexity;
        uint256 lastFee0; // feeGrowthGlobal0X128 at the last sample
        uint96 rateShort; // ETH per day, wei
        uint96 rateLong;
        uint64 depthGwei; // ETH within 2% above the price, in gwei
        uint64 sayShort; // capped: at most CAP_BPS of all pools' uncapped say
        uint64 sayLong;
        uint64 rawShort; // uncapped sqrt(rate x depth) / SAY_UNIT
        uint64 rawLong;
    }

    // one slot per trait family: its pools' summed say and summed ETH fee rate (gwei a day), day and week
    struct Fam {
        uint64 sayS;
        uint64 sayL;
        uint64 rateS;
        uint64 rateL;
    }

    uint256 internal constant SAY_UNIT = 1e6;

    Tracked[] internal tracked;
    mapping(uint32 => uint256) public slotOf; // ref => index + 1

    Fam[6] internal fam;
    uint256 internal famCounts; // six uint32 counts of tracked pools per family
    uint128 internal sayTotS;
    uint128 internal sayTotL;
    uint128 internal rawTotS;
    uint128 internal rawTotL;

    mapping(address => uint256) public earned;
    uint256 public earnedUnpaid;
    uint32 public seasonNo;
    mapping(uint32 => mapping(address => uint32)) public sampledIn;
    address public leadingObserver;

    uint32[10] public hall;
    mapping(uint32 => uint256) public ratingOf;

    struct Position {
        uint32 ref;
        uint128 units; // the pool's second currency, its smallest unit
    }

    Position[10] public portfolio;
    uint256 public navBase = 1e18; // the paper index's value at its last re-weighting, in ETH wei per index unit

    event Tracking(uint32 indexed ref, uint256 slot, uint32 evicted);
    event Sampled(uint32 indexed ref, uint256 feesEth, uint256 rateShort, uint256 depth, uint256 sayShort);
    event Rewarded(address indexed observer, uint256 eth);
    event Reweighted(uint32 indexed season, uint256 nav);

    error NotSprout();
    error AlreadyBound();
    error NotGuide();
    error NotHelix();
    error Unsorted();
    error Stale(uint256 slot);
    error Unlocked();
    error Nothing();

    constructor(IPoolManager manager, address sprout) {
        MANAGER = manager;
        SPROUT = sprout;
    }

    function bind(address guide_, address helix_) external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (bound) revert AlreadyBound();
        bound = true;
        guide = guide_;
        helix = helix_;
    }

    // ------------------------------------------------------------------------------------------------ tracking

    /// @notice By the field guide, when a scout lists an ETH pool (or anyone asks it to retry later). Full: replaces
    ///         the weakest of 16 random slots that either never showed life or has been in view at least 3 days; when
    ///         none qualifies it returns false and the listing stands untracked (it never blocks a listing).
    function track(uint32 ref) external returns (bool) {
        if (msg.sender != guide) revert NotGuide();
        if (slotOf[ref] != 0) return true;
        (bytes32 id, int24 spacing, uint8 mask, uint8 originality, uint8 complexity) = IGuideForLens(guide).entryForLens(ref);
        Tracked memory t;
        t.poolId = id;
        t.ref = ref;
        t.since = uint40(block.timestamp);
        t.lastAt = uint40(block.timestamp);
        t.mask = mask;
        t.spacing = spacing;
        t.originality = originality;
        t.complexity = complexity;
        (,, uint256 fee0,) = _read(id);
        t.lastFee0 = fee0;
        uint32 evicted;
        uint256 slot;
        if (tracked.length < MAX_TRACKED) {
            tracked.push(t);
            slot = tracked.length - 1;
        } else {
            uint256 start = uint256(keccak256(abi.encode(block.prevrandao, ref))) % MAX_TRACKED;
            uint256 weakest = type(uint256).max;
            uint256 weakestSay = type(uint256).max;
            for (uint256 k; k < EVICT_SCAN; ++k) {
                uint256 i = (start + k) % MAX_TRACKED;
                Tracked storage c = tracked[i];
                bool lifeless = c.sayShort == 0 && c.sayLong == 0;
                if (!lifeless && block.timestamp < c.since + TENURE) continue;
                if (c.sayShort < weakestSay) {
                    weakestSay = c.sayShort;
                    weakest = i;
                }
            }
            if (weakest == type(uint256).max) return false;
            Tracked storage old = tracked[weakest];
            _account(old.mask, old.sayShort, old.sayLong, old.rateShort, old.rateLong, 0, 0, 0, 0, false);
            rawTotS -= old.rawShort;
            rawTotL -= old.rawLong;
            evicted = old.ref;
            delete slotOf[evicted];
            tracked[weakest] = t;
            slot = weakest;
        }
        uint256 counts = famCounts;
        for (uint256 f; f < 6; ++f) if ((mask >> f) & 1 == 1) counts += uint256(1) << (32 * f);
        famCounts = counts;
        slotOf[ref] = slot + 1;
        emit Tracking(ref, slot, evicted);
        return true;
    }

    // ------------------------------------------------------------------------------------------------ sampling

    /// @notice Sample tracked pools (slots strictly increasing, each due). Earns BOUNTY per pool while claims last.
    function sample(uint256[] calldata slots) external returns (uint256 paid) {
        // a reading taken inside someone's unlock could see liquidity added and removed in the same transaction
        if (TransientStateLibrary.isUnlocked(MANAGER)) revert Unlocked();
        uint256 last;
        for (uint256 k; k < slots.length; ++k) {
            uint256 i = slots[k];
            if (k != 0 && i <= last) revert Unsorted();
            last = i;
            Tracked storage t = tracked[i];
            if (block.timestamp < t.lastAt + SAMPLE_GAP) revert Stale(i);
            _sample(t);
        }
        uint256 owed = slots.length * BOUNTY;
        uint256 have = MANAGER.balanceOf(address(this), 0);
        uint256 free = have > earnedUnpaid ? have - earnedUnpaid : 0;
        paid = owed < free ? owed : free;
        earned[msg.sender] += paid;
        earnedUnpaid += paid;
        uint32 n = sampledIn[seasonNo][msg.sender] += uint32(slots.length);
        if (msg.sender != leadingObserver && n > sampledIn[seasonNo][leadingObserver]) leadingObserver = msg.sender;
    }

    function _sample(Tracked storage t) internal {
        (uint160 sqrtP, int24 tick, uint256 fee0, uint128 L) = _read(t.poolId);
        uint256 dt = block.timestamp - t.lastAt;
        uint256 fees;
        unchecked {
            fees = FullMath.mulDiv(fee0 - t.lastFee0, L, 1 << 128); // fee growth wraps by design
        }
        if (block.timestamp >= uint256(t.depthAt) + DEPTH_GAP) {
            // depth may at most double (plus 1 ETH) between readings 6 hours apart: a brief deposit counts for little
            uint256 reading = _ethDepth(t.poolId, t.spacing, tick, sqrtP, L) / 1 gwei;
            uint256 ceiling = 2 * uint256(t.depthGwei) + 1e9;
            if (reading > ceiling) reading = ceiling;
            if (reading > type(uint64).max) reading = type(uint64).max;
            t.depthGwei = uint64(reading);
            t.depthAt = uint40(block.timestamp);
        }
        uint256 depth = uint256(t.depthGwei) * 1 gwei;
        // fees are free to fake (self-trading, donating to yourself); only up to 5% of real depth a day counts
        uint256 rate = (fees * 1 days) / dt;
        uint256 rateCap = (depth * RATE_CAP_BPS) / 10_000;
        if (rate > rateCap) rate = rateCap;
        uint256 rs = _ema(t.rateShort, rate, dt, SHORT);
        uint256 rl = _ema(t.rateLong, rate, dt, LONG);
        uint256 rawS = _min(_sqrt(rs * depth) / SAY_UNIT, MAX_SAY);
        uint256 rawL = _min(_sqrt(rl * depth) / SAY_UNIT, MAX_SAY);
        uint256 totS = rawTotS - t.rawShort + rawS;
        uint256 totL = rawTotL - t.rawLong + rawL;
        (rawTotS, rawTotL) = (uint128(totS), uint128(totL));
        // the cap is a share of everyone's uncapped say, so it holds at any number of pools (no collapse when few)
        uint256 sayS = _min(rawS, (totS * CAP_BPS) / 10_000);
        uint256 sayL = _min(rawL, (totL * CAP_BPS) / 10_000);
        _account(t.mask, t.sayShort, t.sayLong, t.rateShort, t.rateLong, sayS, sayL, rs, rl, true);
        t.rateShort = uint96(rs);
        t.rateLong = uint96(rl);
        (t.sayShort, t.sayLong, t.rawShort, t.rawLong) = (uint64(sayS), uint64(sayL), uint64(rawS), uint64(rawL));
        t.lastFee0 = fee0;
        t.lastAt = uint40(block.timestamp);
        _rate(t, sayS);
        emit Sampled(t.ref, fees, rs, depth, sayS);
    }

    function _account(
        uint8 mask,
        uint256 oldS,
        uint256 oldL,
        uint256 oldRs,
        uint256 oldRl,
        uint256 newS,
        uint256 newL,
        uint256 newRs,
        uint256 newRl,
        bool stays
    ) internal {
        (sayTotS, sayTotL) = (uint128(sayTotS - oldS + newS), uint128(sayTotL - oldL + newL));
        uint256 counts = famCounts;
        for (uint256 f; f < 6; ++f) {
            if ((mask >> f) & 1 == 0) continue;
            Fam memory x = fam[f];
            fam[f] = Fam(
                uint64(x.sayS - oldS + newS),
                uint64(x.sayL - oldL + newL),
                uint64(x.rateS - _gwei(oldRs) + _gwei(newRs)),
                uint64(x.rateL - _gwei(oldRl) + _gwei(newRl))
            );
            if (!stays) counts -= uint256(1) << (32 * f);
        }
        if (!stays) famCounts = counts;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev A pool's ETH fee rate in gwei a day, clamped so 192 pools' sum fits a 64-bit field.
    function _gwei(uint256 weiPerDay) internal pure returns (uint256) {
        return _min(weiPerDay / 1 gwei, MAX_SAY);
    }

    function _ema(uint256 prev, uint256 x, uint256 dt, uint256 tau) internal pure returns (uint256) {
        if (dt >= tau) return x;
        if (x >= prev) return prev + ((x - prev) * dt) / tau;
        return prev - ((prev - x) * dt) / tau;
    }

    // ------------------------------------------------------------------------------------------------ PoolManager reads

    function _base(bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, POOLS_SLOT));
    }

    function _read(bytes32 id) internal view returns (uint160 sqrtP, int24 tick, uint256 fee0, uint128 L) {
        bytes32[] memory w = MANAGER.extsload(_base(id), 4);
        uint256 s0 = uint256(w[0]);
        sqrtP = uint160(s0);
        tick = int24(int256(s0 >> 160));
        fee0 = uint256(w[1]);
        L = uint128(uint256(w[3]));
    }

    /// @notice Real ETH resting within 2% above the price of a pool (native ETH as currency0), walking at most 16
    ///         initialized ticks. Used by the gut to size a buyback.
    function ethDepth(bytes32 id, int24 spacing) external view returns (uint256) {
        (uint160 sqrtP, int24 tick,, uint128 L) = _read(id);
        return _ethDepth(id, spacing, tick, sqrtP, L);
    }

    function _ethDepth(bytes32 id, int24 spacing, int24 tick, uint160 sqrtP, uint128 L) internal view returns (uint256 eth) {
        if (sqrtP == 0) return 0;
        int24 limit = tick + DEPTH_TICKS;
        if (limit > TickMath.MAX_TICK) limit = TickMath.MAX_TICK;
        uint160 a = sqrtP;
        int24 cursor = tick;
        uint256 liq = L;
        for (uint256 k; k < MAX_WALK; ++k) {
            (int24 next, bool init) = _nextUp(id, cursor, spacing);
            int24 stop = next > limit ? limit : next;
            uint160 b = TickMath.getSqrtPriceAtTick(stop);
            if (b > a && liq != 0) eth += FullMath.mulDiv(liq << 96, b - a, b) / a;
            if (next >= limit) return eth;
            if (init) {
                int128 net = _liquidityNet(id, next);
                liq = net >= 0 ? liq + uint128(net) : liq - uint128(-net);
            }
            a = b;
            cursor = next;
        }
    }

    /// @dev The next initialized tick strictly above `tick` within one bitmap word, or the word's last tick.
    function _nextUp(bytes32 id, int24 tick, int24 spacing) internal view returns (int24 next, bool init) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        compressed += 1;
        int16 wordPos = int16(compressed >> 8);
        uint8 bitPos = uint8(uint24(compressed) & 0xff);
        bytes32 slot = keccak256(abi.encode(wordPos, uint256(_base(id)) + 5));
        uint256 word = uint256(MANAGER.extsload(slot));
        uint256 masked = word & ~((uint256(1) << bitPos) - 1);
        if (masked != 0) {
            uint8 lsb = _lsb(masked);
            return ((compressed + int24(uint24(lsb)) - int24(uint24(bitPos))) * spacing, true);
        }
        return ((compressed + int24(uint24(type(uint8).max - bitPos))) * spacing, false);
    }

    function _liquidityNet(bytes32 id, int24 tick) internal view returns (int128) {
        bytes32 slot = keccak256(abi.encode(tick, uint256(_base(id)) + 4));
        return int128(int256(uint256(MANAGER.extsload(slot)) >> 128));
    }

    function _lsb(uint256 x) internal pure returns (uint8 r) {
        r = 255;
        if (x & type(uint128).max > 0) r -= 128;
        else x >>= 128;
        if (x & type(uint64).max > 0) r -= 64;
        else x >>= 64;
        if (x & type(uint32).max > 0) r -= 32;
        else x >>= 32;
        if (x & type(uint16).max > 0) r -= 16;
        else x >>= 16;
        if (x & type(uint8).max > 0) r -= 8;
        else x >>= 8;
        if (x & 0xf > 0) r -= 4;
        else x >>= 4;
        if (x & 0x3 > 0) r -= 2;
        else x >>= 2;
        if (x & 0x1 > 0) r -= 1;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    // ------------------------------------------------------------------------------------------------ the brain's view

    /// @notice Per family: [day say share, plain share, week say share, plain share], 1e18 = 100%.
    function familyShares() external view returns (uint256[4][6] memory out) {
        uint256 n = tracked.length;
        uint256 counts = famCounts;
        (uint256 ts, uint256 tl) = (sayTotS, sayTotL);
        for (uint256 f; f < 6; ++f) {
            Fam memory x = fam[f];
            if (n != 0) {
                out[f][1] = (((counts >> (32 * f)) & type(uint32).max) * 1e18) / n;
                out[f][3] = out[f][1];
            }
            // no measured life yet means no signal: the measured share is then the plain share
            out[f][0] = ts != 0 ? (uint256(x.sayS) * 1e18) / ts : out[f][1];
            out[f][2] = tl != 0 ? (uint256(x.sayL) * 1e18) / tl : out[f][3];
        }
    }

    /// @notice A family's summed ETH fee rate over a day and over a week (for the weekly experiment).
    function growthOf(uint256 f) external view returns (uint256, uint256) {
        return (uint256(fam[f].rateS) * 1 gwei, uint256(fam[f].rateL) * 1 gwei);
    }

    function totalSayShort() external view returns (uint256) {
        return sayTotS;
    }

    function totalRawShort() external view returns (uint256) {
        return rawTotS;
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function trackedAt(uint256 i) external view returns (Tracked memory) {
        return tracked[i];
    }

    // ------------------------------------------------------------------------------------------------ hall and index

    /// @notice By the field guide when a challenger proves a copy: its originality, and so its rating, falls to 0.
    function demote(uint32 ref) external {
        if (msg.sender != guide) revert NotGuide();
        uint256 slot = slotOf[ref];
        if (slot == 0) return;
        Tracked storage t = tracked[slot - 1];
        t.originality = 0;
        _rate(t, t.sayShort);
    }

    function _rate(Tracked storage t, uint256 sayS) internal {
        uint32 ref = t.ref;
        uint256 r = (sayS * t.originality * t.complexity) / 10_000;
        ratingOf[ref] = r;
        uint256 at = 10;
        for (uint256 i; i < 10; ++i) {
            if (hall[i] == ref) {
                at = i;
                break;
            }
        }
        if (at == 10) {
            if (hall[9] != 0 && ratingOf[hall[9]] >= r) return;
            at = 9;
            hall[9] = ref;
        }
        // bubble toward its place, both ways (a rating can fall as well as rise)
        while (at > 0 && ratingOf[hall[at - 1]] < r) {
            (hall[at], hall[at - 1]) = (hall[at - 1], ref);
            at--;
        }
        while (at < 9 && hall[at + 1] != 0 && ratingOf[hall[at + 1]] > r) {
            (hall[at], hall[at + 1]) = (hall[at + 1], ref);
            at++;
        }
    }

    function hallOf() external view returns (uint32[10] memory refs, uint256[10] memory ratings) {
        refs = hall;
        for (uint256 i; i < 10; ++i) ratings[i] = ratingOf[refs[i]];
    }

    /// @dev A paper position's ETH value at the pool's price, saturating at TERM_CAP: a collapsed price can make the
    ///      exact value astronomically large, and the index must never be able to revert.
    function _marked(uint256 units, uint160 sqrtP) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(units, Q96, sqrtP); // units < 2^128 and sqrtP >= 2^32: a < 2^192
        if (a >= 1 << 160) return TERM_CAP;
        uint256 b = FullMath.mulDiv(a, Q96, sqrtP);
        return b < TERM_CAP ? b : TERM_CAP;
    }

    /// @notice The paper index's value now, in ETH wei per index unit (1e18 at the start).
    function nav() public view returns (uint256 v) {
        bool any;
        for (uint256 i; i < 10; ++i) {
            Position memory p = portfolio[i];
            if (p.ref == 0) continue;
            any = true;
            uint256 slot = slotOf[p.ref];
            if (slot == 0) continue; // evicted since: counts as zero until the next season
            (uint160 sqrtP,,,) = _read(tracked[slot - 1].poolId);
            if (sqrtP == 0) continue;
            v += _marked(p.units, sqrtP);
        }
        if (!any) v = navBase;
    }

    /// @notice By the helix, every 30 days: a new observer season, and the paper index re-weighted to the Hall.
    function reseason() external {
        if (msg.sender != helix) revert NotHelix();
        seasonNo += 1;
        leadingObserver = address(0);
        uint256 v = nav();
        navBase = v;
        uint256 sum;
        for (uint256 i; i < 10; ++i) sum += ratingOf[hall[i]];
        for (uint256 i; i < 10; ++i) {
            uint32 ref = hall[i];
            uint256 slot = slotOf[ref];
            if (sum == 0 || ref == 0 || slot == 0) {
                delete portfolio[i];
                continue;
            }
            (uint160 sqrtP,,,) = _read(tracked[slot - 1].poolId);
            uint256 share = (v * ratingOf[ref]) / sum; // ETH value placed on this hook
            uint256 units = FullMath.mulDiv(FullMath.mulDiv(share, sqrtP, Q96), sqrtP, Q96); // share <= 10 x 2^120
            if (units > type(uint128).max) units = type(uint128).max;
            portfolio[i] = Position(ref, uint128(units));
        }
        emit Reweighted(seasonNo, v);
    }

    // ------------------------------------------------------------------------------------------------ observers paid

    function withdraw() external returns (uint256 eth) {
        eth = earned[msg.sender];
        if (eth == 0) revert Nothing();
        earned[msg.sender] = 0;
        earnedUnpaid -= eth;
        MANAGER.unlock(abi.encode(msg.sender, eth));
        emit Rewarded(msg.sender, eth);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert NotGuide();
        (address to, uint256 eth) = abi.decode(data, (address, uint256));
        MANAGER.burn(address(this), 0, eth);
        MANAGER.take(Currency.wrap(address(0)), to, eth);
        return "";
    }
}
