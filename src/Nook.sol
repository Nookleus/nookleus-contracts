// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 0: THE TOKEN
//
// Observed: an ERC-20 named Nookleus, symbol NOOK, 18 decimals. 1,000,000,000 minted once, to the sprout (the launch
//   step), which puts them into the pools. No mint function exists after that. Any holder may burn their own.
// Observed: every wallet carries a holding age, the balance-weighted time its NOOK arrived. Receiving dilutes it;
//   sending leaves it alone. The nucleus reads it for the KINSHIP strand (a fee discount for long holders).
// Observed: NECTAR, the holders' drip. ETH fed here is shared by every holder pro rata, counted on every transfer.
//   Pools, the nucleus, the gut and the amber are not holders: their NOOK is excluded from the count.
// Limit, stated: while fewer than 1% of the supply is held outside those, each feed is divided as if 1% were held;
//   the part nobody holds waits here and joins the next feed. So a first buyer cannot take a whole early pot.
// Limit, stated: a holder's share is counted when it is settled (any transfer in or out, or a harvest), from the
//   running total. Integer division leaves at most 1 wei per holder per settlement behind, in this contract.
// Observed, launch protection (Programmable's mandatory policy v1): nothing moves before the sprout starts trading
//   except its own seed into the pool manager. For the first 300 seconds after the start, no address may receive
//   more than 2% of the supply in total; sending, selling or burning never restores the allowance. Transfers into
//   the pool manager (sells, the seed) are not counted, and nobody is exempt from this cap.

interface INookFeeder {
    function feed() external payable;
}

contract Nook {
    string public constant name = "Nookleus";
    string public constant symbol = "NOOK";
    uint8 public constant decimals = 18;
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant FLOOR = SUPPLY / 100; // the smallest count NECTAR ever divides by
    uint256 internal constant SCALE = 1e30;

    address public immutable SPROUT; // the launch step: receives the supply, names the excluded addresses once
    uint256 public constant WALLET_LIMIT_BPS = 200;
    uint256 public constant PROTECTION_SECONDS = 300;
    uint256 public constant walletTokenLimit = (SUPPLY * WALLET_LIMIT_BPS) / 10_000;
    address public immutable poolManager;

    struct Holding {
        uint128 balance;
        uint48 since; // balance-weighted arrival time
        bool excluded; // a pool, the nucleus, the gut, the amber: not a holder for NECTAR
    }

    mapping(address => Holding) internal holding;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public accAt; // the running total when this holder was last settled
    mapping(address => uint256) public owed; // ETH settled to this holder, not yet harvested

    uint256 public totalSupply;
    uint256 public excludedSupply;
    uint256 public acc; // ETH per NOOK, times SCALE, ever fed
    uint256 public waiting; // ETH fed while under the floor, joins the next feed
    uint256 public fedTotal;
    uint256 public harvestedTotal;
    address public nucleus; // the only feeder
    bool public named;
    uint256 public startedAt; // when the sprout started trading (0 before)
    mapping(address => uint256) public receivedDuringProtection;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Fed(uint256 eth, uint256 shared, uint256 waiting);
    event Harvested(address indexed holder, uint256 eth);

    error NotSprout();
    error AlreadyNamed();
    error NotNucleus();
    error Insufficient();
    error NothingOwed();
    error SendFailed();
    error AlreadyStarted();
    error TradingNotStarted();
    error WalletLimitExceeded(address recipient, uint256 attempted, uint256 limit);

    constructor(address sprout, address manager) {
        SPROUT = sprout;
        poolManager = manager;
        totalSupply = SUPPLY;
        holding[sprout] = Holding(uint128(SUPPLY), uint48(block.timestamp), true);
        excludedSupply = SUPPLY;
        emit Transfer(address(0), sprout, SUPPLY);
    }

    /// @notice Once, by the sprout: the nucleus (the only feeder) and the addresses whose NOOK is not a holding.
    function designate(address nucleus_, address[] calldata notHolders) external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (named) revert AlreadyNamed();
        named = true;
        nucleus = nucleus_;
        for (uint256 i; i < notHolders.length; ++i) {
            Holding storage h = holding[notHolders[i]];
            if (!h.excluded) {
                _settle(notHolders[i]);
                h.excluded = true;
                excludedSupply += h.balance;
            }
        }
    }

    /// @notice Once, by the sprout, after its seed and before its first buy: trading starts, the 300 seconds begin.
    function start() external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (startedAt != 0) revert AlreadyStarted();
        startedAt = block.timestamp;
    }

    /// @notice The protection policy names the launch step its initializer and reads the supply as launchSupply.
    function initializer() external view returns (address) {
        return SPROUT;
    }

    function launchSupply() external pure returns (uint256) {
        return SUPPLY;
    }

    // ------------------------------------------------------------------------------------------------ ERC-20

    function balanceOf(address who) external view returns (uint256) {
        return holding[who].balance;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert Insufficient();
            allowance[from][msg.sender] = a - amount;
        }
        _move(from, to, amount);
        return true;
    }

    /// @notice Burn your own NOOK. The gut burns what DIGEST buys back.
    function burn(uint256 amount) external {
        Holding storage h = holding[msg.sender];
        if (h.balance < amount) revert Insufficient();
        if (!h.excluded) _settle(msg.sender);
        else excludedSupply -= amount;
        h.balance -= uint128(amount);
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (amount != 0) {
            uint256 started = startedAt;
            if (started == 0) {
                // only the seed settles before the start
                if (from != SPROUT || to != poolManager) revert TradingNotStarted();
            } else if (block.timestamp < started + PROTECTION_SECONDS && to != poolManager && from != to) {
                uint256 received = receivedDuringProtection[to] + amount;
                if (received > walletTokenLimit) revert WalletLimitExceeded(to, received, walletTokenLimit);
                receivedDuringProtection[to] = received;
            }
        }
        Holding storage f = holding[from];
        uint256 fb = f.balance;
        if (fb < amount) revert Insufficient();
        Holding storage t = holding[to];
        if (!f.excluded) _settle(from);
        else excludedSupply -= amount;
        if (!t.excluded) _settle(to);
        else excludedSupply += amount;
        f.balance = uint128(fb - amount);
        uint256 tb = t.balance; // read after the debit: the same slot when from == to
        if (amount != 0 && from != to && !t.excluded) {
            // the arrival time of the new balance is the balance-weighted mean of the old and now
            t.since = uint48((tb * t.since + amount * block.timestamp) / (tb + amount));
        }
        t.balance = uint128(tb + amount);
        emit Transfer(from, to, amount);
    }

    // ------------------------------------------------------------------------------------------------ KINSHIP

    /// @notice Seconds a wallet has held its current NOOK (balance-weighted), and its balance.
    function ageOf(address who) external view returns (uint256 age, uint256 balance) {
        Holding memory h = holding[who];
        if (h.balance == 0 || h.excluded) return (0, h.balance);
        return (block.timestamp - h.since, h.balance);
    }

    // ------------------------------------------------------------------------------------------------ NECTAR

    /// @notice ETH for every holder, pro rata. Only the nucleus feeds.
    function feed() external payable {
        if (msg.sender != nucleus) revert NotNucleus();
        uint256 amount = msg.value + waiting;
        uint256 eligible = totalSupply - excludedSupply;
        uint256 denom = eligible > FLOOR ? eligible : FLOOR;
        uint256 shared = (amount * eligible) / denom;
        if (eligible != 0) acc += (shared * SCALE) / eligible;
        else shared = 0;
        waiting = amount - shared;
        fedTotal += msg.value;
        emit Fed(msg.value, shared, waiting);
    }

    /// @notice Share what is waiting (fed while under 1% was held) once at least 1% is held. Anyone may call.
    function spread() external {
        uint256 eligible = totalSupply - excludedSupply;
        uint256 amount = waiting;
        if (eligible < FLOOR || amount == 0) revert NothingOwed();
        waiting = 0;
        acc += (amount * SCALE) / eligible;
        emit Fed(0, amount, 0);
    }

    function _settle(address who) internal {
        uint256 a = acc;
        uint256 at = accAt[who];
        if (a == at) return;
        uint256 b = holding[who].balance;
        if (b != 0) owed[who] += (b * (a - at)) / SCALE;
        accAt[who] = a;
    }

    /// @notice ETH this wallet could harvest right now.
    function harvestable(address who) external view returns (uint256) {
        Holding memory h = holding[who];
        if (h.excluded) return owed[who];
        return owed[who] + (uint256(h.balance) * (acc - accAt[who])) / SCALE;
    }

    /// @notice Collect your NECTAR.
    function harvest() external returns (uint256 eth) {
        if (!holding[msg.sender].excluded) _settle(msg.sender);
        eth = owed[msg.sender];
        if (eth == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        harvestedTotal += eth;
        (bool ok,) = msg.sender.call{value: eth}("");
        if (!ok) revert SendFailed();
        emit Harvested(msg.sender, eth);
    }
}
