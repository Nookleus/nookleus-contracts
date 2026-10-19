// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 8: THE SPROUT (the launch, once)
//
// Observed: the sprout holds the whole NOOK supply from birth and can launch exactly once, called by its deployer
//   (the launch graph). In that one call it names the token's non-holders, wires every specimen to the others (the
//   helix, lens, field guide and drawer were born earlier and accept this bind only from code hashing to this
//   sprout's runtime, see Helix.sol), opens
//   each species at its pinned price with the whole band from FLOOR_TICK up to it (NOOK only, the position NFT minted
//   to Amber), and makes the first buy for OWNER with the ETH it was sent, through the nucleus like any trade.
// Observed: whatever NOOK is left over by rounding is burned.
// Observed, launch protection: the ETH species may only open at a fully diluted value of at least USD 15,000, read
//   from Chainlink's ETH/USD feed (at most an hour old) at the moment of launch; below it the whole launch reverts.
//   Trading starts (Nook.start) after the seed and before the first buy, which is required and, like every buy in
//   the first 300 seconds, may bring the owner at most 2% of the supply.

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

interface INookLaunch {
    function designate(address nucleus, address[] calldata notHolders) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function burn(uint256 amount) external;
    function start() external;
}

interface IUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface INucleusLaunch {
    function bind(address helix, address gut, address lens, address guide) external;
    function markOpening(uint256 s) external;
    function keyOf(uint256 s) external view returns (PoolKey memory);
    function speciesCount() external view returns (uint256);
    function speciesInfo(uint256 s) external view returns (bytes32, uint24, int24, int24, bool);
    function FLOOR_TICK() external view returns (int24);
}

interface IBindTwo {
    function bind(address a, address b) external;
}

interface IBindHelix {
    function bind(address lens, address specimens, address nucleus) external;
}

contract Sprout is IUnlockCallback {
    uint256 public constant MINIMUM_FDV_USD = 15_000;
    uint256 public constant SUPPLY = 1_000_000_000e18;
    IUsdFeed public constant ETH_USD = IUsdFeed(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // Chainlink, mainnet
    uint256 public constant MAX_FEED_AGE = 1 hours;
    IPoolManager public immutable MANAGER;
    IPositionManager public immutable POSM;
    IAllowanceTransfer public immutable PERMIT2;
    address public immutable OWNER;
    address public immutable DEPLOYER;
    bool public launched;

    struct Wiring {
        address nook;
        address nucleus;
        address helix;
        address lens;
        address guide;
        address gut;
        address specimens;
        address amber;
    }

    event Launched(uint256 species, uint256 firstBuyEth, uint256 firstBuyNook, uint256 openingFdvUsd);

    error NotDeployer();
    error AlreadyLaunched();
    error BadShares();
    error BelowMinimum();
    error NotManager();
    error NoFirstBuy();
    error BadFeed();
    error OpeningValuationTooLow(uint256 fdvUsd);

    constructor(IPoolManager manager, IPositionManager posm, IAllowanceTransfer permit2, address owner_) {
        MANAGER = manager;
        POSM = posm;
        PERMIT2 = permit2;
        OWNER = owner_;
        DEPLOYER = msg.sender;
    }

    /// @param shares NOOK placed in each species' band (together the whole supply)
    /// @param minOut the least NOOK the first buy may return to OWNER
    function launch(Wiring calldata w, uint256[] calldata shares, uint256 minOut) external payable returns (uint256 bought) {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (launched) revert AlreadyLaunched();
        launched = true;
        INucleusLaunch nucleus = INucleusLaunch(w.nucleus);
        uint256 n = nucleus.speciesCount();
        if (shares.length != n) revert BadShares();
        if (msg.value == 0) revert NoFirstBuy();
        (,,, int24 ethOpen,) = nucleus.speciesInfo(0);
        uint256 fdvUsd = openingFdvUsd(ethOpen);
        if (fdvUsd < MINIMUM_FDV_USD) revert OpeningValuationTooLow(fdvUsd);

        address[] memory notHolders = new address[](4);
        notHolders[0] = address(MANAGER);
        notHolders[1] = w.nucleus;
        notHolders[2] = w.gut;
        notHolders[3] = w.amber;
        INookLaunch(w.nook).designate(w.nucleus, notHolders);
        nucleus.bind(w.helix, w.gut, w.lens, w.guide);
        IBindHelix(w.helix).bind(w.lens, w.specimens, w.nucleus);
        IBindTwo(w.lens).bind(w.guide, w.helix);
        IBindTwo(w.guide).bind(w.lens, w.specimens);
        IBindTwo(w.specimens).bind(w.guide, w.helix);

        INookLaunch(w.nook).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(w.nook, address(POSM), type(uint160).max, type(uint48).max);
        int24 floor = nucleus.FLOOR_TICK();
        for (uint256 s; s < n; ++s) {
            PoolKey memory key = nucleus.keyOf(s);
            (,,, int24 openTick,) = nucleus.speciesInfo(s);
            uint160 top = TickMath.getSqrtPriceAtTick(openTick);
            MANAGER.initialize(key, top);
            nucleus.markOpening(s);
            uint256 liquidity = FullMath.mulDiv(shares[s], 1 << 96, top - TickMath.getSqrtPriceAtTick(floor));
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(key, floor, openTick, liquidity, uint128(0), uint128(shares[s]), w.amber, bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1);
            POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }

        INookLaunch(w.nook).start();
        bought = abi.decode(MANAGER.unlock(abi.encode(nucleus.keyOf(0), msg.value)), (uint256));
        if (bought < minOut) revert BelowMinimum();
        uint256 left = INookLaunch(w.nook).balanceOf(address(this));
        if (left != 0) INookLaunch(w.nook).burn(left);
        emit Launched(n, msg.value, bought, fdvUsd);
    }

    /// @notice The whole supply's value in USD at an opening tick of the ETH species, from Chainlink's ETH/USD.
    function openingFdvUsd(int24 openTick) public view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updated, uint80 answeredRound) = ETH_USD.latestRoundData();
        if (answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > MAX_FEED_AGE || answeredRound < round || round == 0) {
            revert BadFeed();
        }
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(openTick);
        // ETH is currency0: the supply's value in wei is SUPPLY * 2^192 / sqrtP^2, rounded down
        uint256 wei_ = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sqrtP), 1 << 96, sqrtP);
        return FullMath.mulDiv(wei_, uint256(answer), 1 ether * 10 ** ETH_USD.decimals());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(MANAGER)) revert NotManager();
        (PoolKey memory key, uint256 eth) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta d = MANAGER.swap(key, SwapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1), "");
        MANAGER.settle{value: uint256(-int256(d.amount0()))}();
        uint256 got = uint256(int256(d.amount1()));
        MANAGER.take(key.currency1, OWNER, got);
        return abi.encode(got);
    }
}
