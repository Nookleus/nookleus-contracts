// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 1: THE NUCLEUS (the v4 hook)
//
// Observed: one hook for every Nookleus pool ("species"), each native ETH against NOOK. Each species carries its own
//   six strands, levels 0 to 8, which the helix moves at most one step an hour (see Helix.sol).
// Observed, on the ETH side of every trade, buy or sell, whichever amount the trader named:
//   0.30% to Programmable (minted as ETH claims to their unmodified fee vault, rounded up, every swap),
//   1.5% to the owner (fixed), and a module fee (1% base) the strands share. Owner plus module never exceed 3.5%.
//   Every species pool has a 0% LP fee (the constructor refuses any other): the hook's charge is the whole fee.
// Observed, the strands:
//   TEMPER   a surcharge up to 0.125% per level, scaled by how far the price sits from its 10-minute mean (200 ticks
//            away counts as fully volatile)
//   KINSHIP  6.25% off the module fee per level, when tx.origin has held at least 1,000,000 NOOK for 7 days
//   NECTAR   7.5% of the module fee per level to every holder (fed to the token)
//   DIGEST   7.5% per level to buybacks the gut burns; it also takes whatever no strand claims
//   ROOTS    2.5% per level to liquidity the gut plants under the price and never removes
//   SPORES   2.5% per level to a pot the helix releases into NECTAR at random hours
//   Before the strands, 10% of a trade's module fee goes to the scout of the hook the buyer pledged (hookData), and
//   5% of every module fee goes to the observers who keep the readings fresh.
// Observed: module fees are split into those books when the strands change (and whenever anyone asks), not on every
//   trade. Levels only change at a mutation, so the split is exact and a trade writes one slot instead of five.
// Observed: a swap that names its ETH amount fills completely or reverts; a swap moving no ETH reverts.
// Observed: liquidity enters only twice: the launch band, once, inside the sprout's opening step, and the gut's
//   ROOTS. Nothing is ever removed; collecting fees (a zero change) is allowed.
// Observed, launch protection (Programmable's mandatory policy v1, through their unmodified LaunchProtectionModuleV1,
//   created here as CREATE child 2 between the fee vault and the opening-tax vault):
//   for the first 300 seconds after the start, a buy must come from the canonical Universal Router (whose msgSender
//   is the buyer) or from the sprout's first buy (counted as the owner's); each buyer may take at most 2% of the
//   supply in total. For the first 30 seconds every buy also pays an opening surcharge, so that the total starts at
//   99% and falls linearly to the normal fee; the surcharge is minted to a separate vault that only Programmable's
//   treasury can claim. The owner and up to six named wallets skip the surcharge but keep the 2% limit. Sells pay
//   normal fees throughout. The token itself caps what any address receives in those 300 seconds (Nook.sol).
// Limit, stated: KINSHIP reads tx.origin. A bot trading through an aged wallet gets the discount too.
// Limit, stated: the hourly pulse can ride on a trade (the first one after it falls due pays for it), with at most
//   1,200,000 gas lent to it; if it fails for any reason the trade still goes through and the pulse is retried 15
//   minutes later. No loop over pools or holders runs on this path.

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {EthereumNativeFeeVaultV3} from "./vendor/EthereumNativeFeeVaultV3.sol";
import {LaunchProtectionModuleV1} from "./vendor/LaunchProtectionModuleV1.sol";
import {ProtectedLaunchTokenV1} from "./vendor/ProtectedLaunchTokenV1.sol";
import {INookToken, IHelix, IFieldGuide} from "./Interfaces.sol";

interface IGutFund {
    function fund(uint256 digest, uint256 roots) external;
}

contract Nucleus is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------------------------------------ fixed in code
    uint256 internal constant PIPS = 1_000_000;
    uint256 public constant PLATFORM_PIPS = 3_000;
    uint256 public constant OWNER_PIPS = 15_000;
    uint256 public constant MODULE_PIPS = 10_000;
    uint256 public constant HOOK_CAP_PIPS = 35_000;
    uint256 public constant TEMPER_STEP_PIPS = 1_250;
    uint256 public constant KIN_STEP_BPS = 625;
    uint256 public constant KIN_AGE = 7 days;
    uint256 public constant KIN_MIN = 1_000_000e18;
    uint256 public constant PLEDGE_SLICE_BPS = 1_000;
    uint256 public constant OBSERVER_BPS = 500;
    uint256 public constant NECTAR_STEP_BPS = 750;
    uint256 public constant DIGEST_STEP_BPS = 750;
    uint256 public constant ROOTS_STEP_BPS = 250;
    uint256 public constant SPORES_STEP_BPS = 250;
    uint8 public constant LEVELS = 8;
    uint8 public constant START_LEVEL = 4;
    int24 public constant FLOOR_TICK = -887_220;
    uint256 public constant VOL_TICKS = 200;
    uint256 public constant VOL_WINDOW = 600;
    uint256 public constant PULSE_GAS = 1_200_000; // the most a trade lends the helix; measured worst case 0.55M
    uint256 public constant PULSE_RETRY = 15 minutes;
    uint256 public constant OPENING_TOTAL_PIPS = 990_000; // the most a buy pays in total while the surcharge runs
    uint256 public constant PROTECTION_SECONDS = 300;
    uint256 public constant BUYER_LIMIT = 20_000_000e18; // 2% of the supply, per buyer, in the first 300 seconds
    uint16 public constant NORMAL_CREATOR_BUY_BPS = 250; // owner 1.5% + module 1%: the normal buy fee the module tapers to

    uint8 internal constant TEMPER = 0;
    uint8 internal constant KINSHIP = 1;
    uint8 internal constant NECTAR = 2;
    uint8 internal constant DIGEST = 3;
    uint8 internal constant ROOTS = 4;
    uint8 internal constant SPORES = 5;

    IPoolManager public immutable MANAGER;
    address public immutable OWNER;
    address public immutable NOOK;
    address public immutable SPROUT;

    // Programmable binds the fee vault by the hook's CREATE nonce 1; it lives in storage so their two-pass address
    // prediction holds.
    EthereumNativeFeeVaultV3 public feeVault;
    LaunchProtectionModuleV1 public protection; // CREATE child 2
    EthereumNativeFeeVaultV3 public openingTaxVault; // CREATE child 3: opening surcharges, Programmable's only
    mapping(address => uint256) public boughtDuringProtection;

    address public helix;
    address public gut;
    address public lens;
    address public guide;
    bool public bound;

    struct Species {
        bytes32 id;
        uint24 lpFee;
        int24 spacing;
        int24 openTick;
        bool opened;
    }

    Species[] internal species;
    mapping(bytes32 => uint256) internal indexOf; // pool id => species index + 1

    struct Accrual {
        uint128 module; // module fees not yet split into books
        uint128 owner; // owner fees not yet remitted
    }

    mapping(uint256 => uint48) internal strands; // six levels, 8 bits each, TEMPER in the low byte
    mapping(uint256 => uint256) internal temper; // int128 mean tick x 16 | uint64 last update
    mapping(uint256 => Accrual) public accrual;
    mapping(uint256 => uint256) internal pledge; // uint64 hour stamp << 192 | six uint32 EMAs in 1e12 wei
    uint64 public nextPulseAt;

    uint256 public nectarBook;
    uint256 public digestBook;
    uint256 public rootsBook;
    uint256 public sporeBook;
    uint256 public observerBook;
    mapping(uint32 => uint256) public scoutBook; // by FieldGuide reference

    struct Call {
        uint32 hour; // the hour whose preview it predicts
        uint8 code; // 0x80 | species << 4 | strand << 1 | (up ? 1 : 0)
    }

    mapping(address => Call) internal calls;

    // transient: the opening species (+1) during the sprout's step, and the per-swap context
    bytes32 internal constant T_OPENING = keccak256("nookleus.nucleus.opening");
    bytes32 internal constant T_SWAP = keccak256("nookleus.nucleus.swap");
    bytes32 internal constant T_GUARD = keccak256("nookleus.nucleus.protection"); // surcharge pips << 160 | buyer

    event Bound(address helix, address gut, address lens, address guide);
    event Opened(uint256 indexed species, uint256 liquidity);
    event Charged(uint256 indexed species, bool buy, uint256 gross, uint256 platform, uint256 owner, uint256 module, uint32 pledgedRef);
    event Split(uint256 indexed species, uint256 module, uint256 nectar, uint256 digest, uint256 roots, uint256 spores, uint256 observers);
    event StrandsSet(uint256 indexed species, uint48 levels);
    event Called(address indexed caller, uint32 hour, uint8 code);
    event Flowed(uint256 nectar, uint256 spores, uint256 digest, uint256 roots, uint256 observers);
    event OwnerRemitted(uint256 eth);
    event ScoutPaid(uint32 indexed ref, address indexed scout, uint256 eth);
    event PulseSkipped(uint64 at);
    event OpeningTaxAccrued(uint256 indexed species, address indexed buyer, uint256 gross, uint256 amount);

    error NotManager();
    error NotSprout();
    error NotHelix();
    error NotGut();
    error AlreadyBound();
    error WrongPool();
    error WrongPrice();
    error WrongBand();
    error Closed();
    error NoRemoval();
    error PartialFill();
    error NoEth();
    error TooLarge();
    error BadCall();
    error Nothing();
    error NotScout();
    error Unused();
    error BuyerLimitExceeded(address buyer, uint256 attempted, uint256 limit);

    modifier onlyManager() {
        if (msg.sender != address(MANAGER)) revert NotManager();
        _;
    }

    /// @param openTicks the opening tick of each species (its whole band runs from FLOOR_TICK up to it)
    /// @param router the canonical Universal Router the protection module accepts, and its runtime code hash
    /// @param exemptWallets up to six wallets (zero = unused) that skip the opening surcharge, besides the owner
    constructor(
        IPoolManager manager,
        address owner_,
        address nook,
        address sprout,
        uint24[] memory lpFees,
        int24[] memory spacings,
        int24[] memory openTicks,
        address router,
        bytes32 routerCodeHash,
        address[6] memory exemptWallets
    ) {
        MANAGER = manager;
        OWNER = owner_;
        NOOK = nook;
        SPROUT = sprout;
        feeVault = new EthereumNativeFeeVaultV3(manager, owner_);
        protection = new LaunchProtectionModuleV1(
            address(this), ProtectedLaunchTokenV1(nook), owner_, router, routerCodeHash, NORMAL_CREATOR_BUY_BPS, exemptWallets
        );
        openingTaxVault = new EthereumNativeFeeVaultV3(manager, feeVault.PLATFORM_RECIPIENT());
        if (lpFees.length == 0 || lpFees.length > 2 || spacings.length != lpFees.length || openTicks.length != lpFees.length) {
            revert WrongPool();
        }
        for (uint256 i; i < lpFees.length; ++i) {
            if (lpFees[i] != 0) revert WrongPool(); // no LP fee: the hook's charge is the whole fee
            PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(nook), lpFees[i], spacings[i], IHooks(address(this)));
            bytes32 id = PoolId.unwrap(key.toId());
            species.push(Species(id, lpFees[i], spacings[i], openTicks[i], false));
            indexOf[id] = i + 1;
            strands[i] = _uniform(START_LEVEL);
        }
    }

    receive() external payable {
        if (msg.sender != address(MANAGER)) revert NotManager();
    }

    /// @notice Once, by the sprout: the other specimens.
    function bind(address helix_, address gut_, address lens_, address guide_) external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (bound) revert AlreadyBound();
        bound = true;
        (helix, gut, lens, guide) = (helix_, gut_, lens_, guide_);
        emit Bound(helix_, gut_, lens_, guide_);
    }

    /// @notice By the sprout, inside its launch step: the next liquidity add may be this species' launch band.
    function markOpening(uint256 s) external {
        if (msg.sender != SPROUT) revert NotSprout();
        bytes32 slot = T_OPENING;
        assembly {
            tstore(slot, add(s, 1))
        }
    }

    // ------------------------------------------------------------------------------------------------ admission

    function getHookPermissions() public pure returns (uint160 flags) {
        // beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap | both swap deltas
        return 0x2ACC;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyManager
        returns (bytes4)
    {
        if (sender != SPROUT) revert NotSprout();
        uint256 s = _speciesOf(key);
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(species[s].openTick)) revert WrongPrice();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata)
        external
        onlyManager
        returns (bytes4)
    {
        uint256 s = _speciesOf(key);
        Species storage sp = species[s];
        if (!sp.opened) {
            uint256 opening;
            bytes32 slot = T_OPENING;
            assembly {
                opening := tload(slot)
            }
            if (opening != s + 1) revert Closed();
            if (p.tickLower != FLOOR_TICK || p.tickUpper != sp.openTick || p.liquidityDelta <= 0) revert WrongBand();
            sp.opened = true;
            assembly {
                tstore(slot, 0)
            }
            emit Opened(s, uint256(p.liquidityDelta));
        } else if (sender != gut) {
            revert Closed();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata)
        external
        view
        onlyManager
        returns (bytes4)
    {
        _speciesOf(key);
        if (p.liquidityDelta != 0) revert NoRemoval(); // collecting fees only
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ------------------------------------------------------------------------------------------------ the swap

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata p, bytes calldata data)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 s = _speciesOf(key);
        if (!species[s].opened) revert Closed();
        if (block.timestamp >= nextPulseAt && helix != address(0)) _pulse();
        uint256 modulePips = _modulePips(s, key);
        uint256 taxPips = _guard(sender, p.zeroForOne, modulePips);
        bool ethNamed = (p.amountSpecified < 0) == p.zeroForOne; // exact-in buy, or exact-out sell
        if (!ethNamed) {
            _stash(s, modulePips, false, 0);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        uint256 named = p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        if (named == 0) revert NoEth();
        uint256 rate = PLATFORM_PIPS + OWNER_PIPS + modulePips + taxPips;
        uint256 gross;
        uint256 total;
        uint256 expected;
        if (p.zeroForOne) {
            // exact ETH in: the fee comes off the ETH before it reaches the pool
            gross = named;
            total = _ceilDiv(named * rate, PIPS);
            if (total >= named) revert NoEth();
            expected = named - total;
        } else {
            // exact ETH out: the pool pays out the gross, the trader receives the named amount
            gross = _ceilDiv(named * PIPS, PIPS - rate);
            total = gross - named;
            expected = gross;
        }
        _stash(s, modulePips, true, expected);
        _charge(s, p.zeroForOne, gross, total, _surcharge(gross, total, rate, taxPips), data);
        if (total > uint128(type(int128).max)) revert TooLarge();
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(total)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata p, BalanceDelta d, bytes calldata data)
        external
        onlyManager
        returns (bytes4, int128)
    {
        (uint256 s, uint256 modulePips, bool ethNamed, uint256 expected) = _unstash();
        (uint256 taxPips, address buyer) = _unguard();
        if (buyer != address(0)) {
            // the protection window: what this buyer has taken in total, never over 2% of the supply
            uint256 bought = boughtDuringProtection[buyer] + (d.amount1() > 0 ? uint256(int256(d.amount1())) : 0);
            if (bought > BUYER_LIMIT) revert BuyerLimitExceeded(buyer, bought, BUYER_LIMIT);
            boughtDuringProtection[buyer] = bought;
        }
        int128 a0 = d.amount0();
        uint256 eth = a0 < 0 ? uint256(-int256(a0)) : uint256(int256(a0));
        if (ethNamed) {
            if (eth != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        if (eth == 0) revert NoEth();
        uint256 rate = PLATFORM_PIPS + OWNER_PIPS + modulePips + taxPips;
        uint256 gross;
        uint256 total;
        if (p.zeroForOne) {
            // exact NOOK out: the pool took `eth`; the trader pays the gross
            gross = _ceilDiv(eth * PIPS, PIPS - rate);
            total = gross - eth;
        } else {
            // exact NOOK in: the pool paid out `eth`; the fee comes off it
            gross = eth;
            total = _ceilDiv(eth * rate, PIPS);
        }
        _charge(s, p.zeroForOne, gross, total, _surcharge(gross, total, rate, taxPips), data);
        if (total > uint128(type(int128).max)) revert TooLarge();
        return (IHooks.afterSwap.selector, int128(int256(total)));
    }

    /// @dev The helix's work rides on a trade but can never stop it: capped gas, and any failure is caught (the trade
    ///      goes through, the pulse is retried 15 minutes later, by a trade or by anyone calling the helix).
    function _pulse() internal {
        try IHelix(helix).pulse{gas: PULSE_GAS}() returns (uint64 next) {
            nextPulseAt = next;
        } catch {
            nextPulseAt = uint64(block.timestamp + PULSE_RETRY);
            emit PulseSkipped(uint64(block.timestamp));
        }
    }

    /// @dev Mints the claims, records the platform share, books the owner and module shares, pledges and calls.
    function _charge(uint256 s, bool buy, uint256 gross, uint256 total, uint256 tax, bytes calldata data) internal {
        if (tax != 0) {
            MANAGER.mint(address(openingTaxVault), 0, tax);
            openingTaxVault.recordFees(tax, 0);
            emit OpeningTaxAccrued(s, tx.origin, gross, tax);
            total -= tax;
        }
        uint256 platform = _ceilDiv(gross * PLATFORM_PIPS, PIPS);
        if (platform > total) platform = total;
        uint256 owner = (gross * OWNER_PIPS) / PIPS;
        if (owner > total - platform) owner = total - platform;
        uint256 module = total - platform - owner;
        if (platform != 0) {
            MANAGER.mint(address(feeVault), 0, platform);
            feeVault.recordFees(platform, 0);
        }
        if (total != platform) MANAGER.mint(address(this), 0, total - platform);

        uint32 ref;
        if (data.length >= 32) {
            uint256 word = abi.decode(data, (uint256));
            ref = uint32(word);
            uint8 code = uint8(word >> 32);
            if (code != 0) _call(tx.origin, code);
            if (ref != 0 && guide != address(0)) {
                (uint8 mask, bool listed) = IFieldGuide(guide).familiesOf(ref);
                if (listed) {
                    uint256 slice = (module * PLEDGE_SLICE_BPS) / 10_000;
                    scoutBook[ref] += slice;
                    _pledge(s, mask, module);
                    module -= slice;
                } else {
                    ref = 0;
                }
            }
        }
        Accrual storage a = accrual[s];
        a.module += uint128(module);
        a.owner += uint128(owner);
        emit Charged(s, buy, gross, platform, owner, module, ref);
    }

    /// @dev The module fee after TEMPER and KINSHIP, capped so owner + module stay within HOOK_CAP_PIPS.
    function _modulePips(uint256 s, PoolKey calldata key) internal returns (uint256 m) {
        uint48 lv = strands[s];
        m = MODULE_PIPS;
        uint256 tl = uint8(lv >> (8 * TEMPER));
        if (tl != 0) {
            (, int24 tick,,) = MANAGER.getSlot0(key.toId());
            m += (tl * TEMPER_STEP_PIPS * _volatility(s, tick)) / 10_000;
        }
        uint256 kl = uint8(lv >> (8 * KINSHIP));
        if (kl != 0) {
            (uint256 age, uint256 bal) = INookToken(NOOK).ageOf(tx.origin);
            if (age >= KIN_AGE && bal >= KIN_MIN) m -= (m * kl * KIN_STEP_BPS) / 10_000;
        }
        if (OWNER_PIPS + m > HOOK_CAP_PIPS) m = HOOK_CAP_PIPS - OWNER_PIPS;
    }

    /// @dev 0..10_000: how far the tick sits from its 10-minute mean, 200 ticks or more = 10_000. Updates the mean.
    function _volatility(uint256 s, int24 tick) internal returns (uint256 vol) {
        uint256 w = temper[s];
        int256 now16 = int256(tick) * 16;
        int256 mean = int256(int128(uint128(w >> 64)));
        uint256 at = uint64(w);
        uint256 dt = block.timestamp - at;
        if (at == 0 || dt >= VOL_WINDOW) mean = now16;
        else mean += ((now16 - mean) * int256(dt)) / int256(VOL_WINDOW);
        temper[s] = (uint256(uint128(int128(mean))) << 64) | block.timestamp;
        uint256 dist = uint256(now16 > mean ? now16 - mean : mean - now16);
        vol = (dist * 10_000) / (VOL_TICKS * 16);
        if (vol > 10_000) vol = 10_000;
    }

    // ------------------------------------------------------------------------------------------------ pledges, calls

    /// @dev Six hourly-decaying sums (24 h time constant) of module fees pledged toward each trait family.
    function _pledge(uint256 s, uint8 mask, uint256 amount) internal {
        uint256[6] memory v = _decayed(pledge[s]);
        uint256 add = amount / 1e12;
        uint256 packed = (block.timestamp / 3600) << 192;
        for (uint256 f; f < 6; ++f) {
            uint256 x = v[f] + ((mask >> f) & 1 == 1 ? add : 0);
            if (x > type(uint32).max) x = type(uint32).max;
            packed |= x << (32 * f);
        }
        pledge[s] = packed;
    }

    function _decayed(uint256 w) internal view returns (uint256[6] memory v) {
        uint256 hours_ = block.timestamp / 3600 - (w >> 192);
        if (w == 0 || hours_ >= 24 * 14) return v;
        // (23/24)^hours in 1e18, by squaring
        uint256 factor = 1e18;
        uint256 b = uint256(23e18) / 24;
        for (uint256 e = hours_; e != 0; e >>= 1) {
            if (e & 1 == 1) factor = (factor * b) / 1e18;
            b = (b * b) / 1e18;
        }
        for (uint256 f; f < 6; ++f) v[f] = (((w >> (32 * f)) & type(uint32).max) * factor) / 1e18;
    }

    /// @notice Pledged module fees per trait family for a species, decayed to now, in wei.
    function pledgesOf(uint256 s) external view returns (uint256[6] memory v) {
        v = _decayed(pledge[s]);
        for (uint256 f; f < 6; ++f) v[f] *= 1e12;
    }

    /// @notice A free mutation call: guess the next step of a species (no trade needed).
    function predict(uint8 code) external {
        _call(msg.sender, code);
    }

    function _call(address who, uint8 code) internal {
        if (code & 0x80 == 0 || (code >> 4) & 0x7 >= species.length || (code >> 1) & 0x7 >= 6) revert BadCall();
        // a call before :45 predicts this hour's preview; at or after :45, the next hour's
        uint256 hour = block.timestamp / 3600;
        if (block.timestamp % 3600 >= 2700) hour += 1;
        calls[who] = Call(uint32(hour), code);
        emit Called(who, uint32(hour), code);
    }

    function callOf(address who) external view returns (uint32 hour, uint8 code) {
        Call memory c = calls[who];
        return (c.hour, c.code);
    }

    // ------------------------------------------------------------------------------------------------ the strands

    function strandsOf(uint256 s) external view returns (uint8[6] memory lv) {
        uint48 w = strands[s];
        for (uint256 f; f < 6; ++f) lv[f] = uint8(w >> (8 * f));
    }

    /// @notice By the helix only: new levels for a species (module fees so far are split at the old levels first).
    function setStrands(uint256 s, uint8[6] calldata lv, uint64 nextPulseAt_) external {
        if (msg.sender != helix) revert NotHelix();
        _split(s);
        uint48 w;
        for (uint256 f; f < 6; ++f) {
            if (lv[f] > LEVELS) revert TooLarge();
            w |= uint48(uint256(lv[f]) << (8 * f));
        }
        strands[s] = w;
        nextPulseAt = nextPulseAt_;
        emit StrandsSet(s, w);
    }

    /// @notice Split a species' module fees into the books at its current levels. Anyone may call.
    function split(uint256 s) external {
        if (s >= species.length) revert WrongPool();
        _split(s);
    }

    function _split(uint256 s) internal {
        uint256 m = accrual[s].module;
        if (m == 0) return;
        accrual[s].module = 0;
        uint256 obs = (m * OBSERVER_BPS) / 10_000;
        m -= obs;
        uint48 lv = strands[s];
        uint256 n = (m * uint8(lv >> (8 * NECTAR)) * NECTAR_STEP_BPS) / 10_000;
        uint256 dg = (m * uint8(lv >> (8 * DIGEST)) * DIGEST_STEP_BPS) / 10_000;
        uint256 r = (m * uint8(lv >> (8 * ROOTS)) * ROOTS_STEP_BPS) / 10_000;
        uint256 sp = (m * uint8(lv >> (8 * SPORES)) * SPORES_STEP_BPS) / 10_000;
        uint256 sum = n + dg + r + sp;
        if (sum > m) {
            n = (n * m) / sum;
            dg = (dg * m) / sum;
            r = (r * m) / sum;
            sp = (sp * m) / sum;
            sum = n + dg + r + sp;
        }
        dg += m - sum; // what no strand claims goes to DIGEST
        nectarBook += n;
        digestBook += dg;
        rootsBook += r;
        sporeBook += sp;
        observerBook += obs;
        emit Split(s, m + obs, n, dg, r, sp, obs);
    }

    // ------------------------------------------------------------------------------------------------ paying out

    /// @notice Move the books: NECTAR (and SPORES when the helix says it is a spore hour) to every holder, DIGEST and
    ///         ROOTS claims to the gut, the observers' claims to the lens. Anyone may call.
    function flow() external {
        if (!bound) revert Closed();
        for (uint256 s; s < species.length; ++s) _split(s);
        uint256 n = nectarBook;
        uint256 sp;
        if (sporeBook != 0 && helix != address(0)) {
            for (uint256 s; s < species.length; ++s) {
                if (IHelix(helix).sporeHour(s)) {
                    sp = sporeBook;
                    break;
                }
            }
        }
        uint256 dg = digestBook;
        uint256 r = rootsBook;
        uint256 obs = observerBook;
        nectarBook = 0;
        sporeBook -= sp;
        digestBook = 0;
        rootsBook = 0;
        observerBook = 0;
        if (dg + r != 0) {
            MANAGER.transfer(gut, 0, dg + r);
            IGutFund(gut).fund(dg, r);
        }
        if (obs != 0) MANAGER.transfer(lens, 0, obs);
        if (n + sp != 0) {
            MANAGER.unlock(abi.encode(address(this), n + sp));
            INookToken(NOOK).feed{value: n + sp}();
        }
        emit Flowed(n, sp, dg, r, obs);
    }

    /// @notice By the gut: ROOTS fees it minted here as claims, for NECTAR.
    function creditNectar(uint256 eth) external {
        if (msg.sender != gut) revert NotGut();
        nectarBook += eth;
    }

    /// @notice Pay the owner everything owed. Anyone may call; the ETH goes only to OWNER.
    function remitOwner() external returns (uint256 eth) {
        for (uint256 s; s < species.length; ++s) {
            eth += accrual[s].owner;
            accrual[s].owner = 0;
        }
        if (eth == 0) revert Nothing();
        MANAGER.unlock(abi.encode(OWNER, eth));
        emit OwnerRemitted(eth);
    }

    /// @notice The scout of a pledged hook collects its slices.
    function payScout(uint32 ref) external returns (uint256 eth) {
        if (IFieldGuide(guide).scoutOf(ref) != msg.sender) revert NotScout();
        eth = scoutBook[ref];
        if (eth == 0) revert Nothing();
        scoutBook[ref] = 0;
        MANAGER.unlock(abi.encode(msg.sender, eth));
        emit ScoutPaid(ref, msg.sender, eth);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        (address to, uint256 eth) = abi.decode(data, (address, uint256));
        MANAGER.burn(address(this), 0, eth);
        MANAGER.take(Currency.wrap(address(0)), to, eth);
        return "";
    }

    // ------------------------------------------------------------------------------------------------ views

    function speciesCount() external view returns (uint256) {
        return species.length;
    }

    function poolIdOf(uint256 s) external view returns (bytes32) {
        return species[s].id;
    }

    function speciesInfo(uint256 s) external view returns (Species memory) {
        return species[s];
    }

    function keyOf(uint256 s) public view returns (PoolKey memory) {
        Species memory sp = species[s];
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(NOOK), sp.lpFee, sp.spacing, IHooks(address(this)));
    }

    // ------------------------------------------------------------------------------------------------ internals

    function _speciesOf(PoolKey calldata key) internal view returns (uint256) {
        uint256 i = indexOf[PoolId.unwrap(key.toId())];
        if (i == 0) revert WrongPool();
        return i - 1;
    }

    /// @dev The protection policy for one swap: who is buying inside the window (0 outside it, or for a sell) and the
    ///      opening surcharge in pips, kept so that the total never exceeds OPENING_TOTAL_PIPS. Bound to this swap.
    function _guard(address sender, bool buy, uint256 modulePips) internal returns (uint256 taxPips) {
        address buyer;
        if (buy) {
            if (block.timestamp < INookToken(NOOK).startedAt() + PROTECTION_SECONDS) buyer = protection.protectedBuyer(sender);
            taxPips = protection.openingTaxPpmForSender(sender);
            uint256 normal = PLATFORM_PIPS + OWNER_PIPS + modulePips;
            if (taxPips + normal > OPENING_TOTAL_PIPS) taxPips = normal >= OPENING_TOTAL_PIPS ? 0 : OPENING_TOTAL_PIPS - normal;
        }
        bytes32 slot = T_GUARD;
        uint256 w = (taxPips << 160) | uint256(uint160(buyer));
        assembly {
            tstore(slot, w)
        }
    }

    function _unguard() internal returns (uint256 taxPips, address buyer) {
        bytes32 slot = T_GUARD;
        uint256 w;
        assembly {
            w := tload(slot)
            tstore(slot, 0)
        }
        taxPips = w >> 160;
        buyer = address(uint160(w));
    }

    /// @dev The surcharge part of a charge: the total less the normal fee on the same gross, both rounded up.
    function _surcharge(uint256 gross, uint256 total, uint256 rate, uint256 taxPips) internal pure returns (uint256) {
        if (taxPips == 0) return 0;
        uint256 normal = _ceilDiv(gross * (rate - taxPips), PIPS);
        return total > normal ? total - normal : 0;
    }

    function _stash(uint256 s, uint256 modulePips, bool ethNamed, uint256 expected) internal {
        bytes32 slot = T_SWAP;
        uint256 w = (expected << 64) | (s << 40) | (modulePips << 8) | (ethNamed ? 1 : 0);
        if (expected >= 1 << 192) revert TooLarge();
        assembly {
            tstore(slot, w)
        }
    }

    function _unstash() internal view returns (uint256 s, uint256 modulePips, bool ethNamed, uint256 expected) {
        bytes32 slot = T_SWAP;
        uint256 w;
        assembly {
            w := tload(slot)
        }
        ethNamed = w & 1 == 1;
        modulePips = (w >> 8) & 0xffffffff;
        s = (w >> 40) & 0xffffff;
        expected = w >> 64;
    }

    function _uniform(uint8 level) internal pure returns (uint48 w) {
        for (uint256 f; f < 6; ++f) w |= uint48(uint256(level) << (8 * f));
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ------------------------------------------------------------------------------------------------ never called

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert Unused();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert Unused();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert Unused();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Unused();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert Unused();
    }
}
