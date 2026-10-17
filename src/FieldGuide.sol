// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 4: THE FIELD GUIDE (every hook a scout has listed)
//
// Observed, listing: anyone (a person or an agent) lists a v4 pool with a 0.002 ETH deposit, which only blocks spam.
//   The pool must exist and its hook must have code. Read once, from Ethereum alone (the hook's code is read, never
//   run): its 14 abilities (the address bits), a dynamic fee (the pool key), what it trades (native ETH, a dollar
//   stable, or other), its fee and tick spacing, its code size and code hash, and the hash of its code without the
//   compiler's metadata trailer.
// Observed, families: a family is the 14 ability bits plus the dynamic-fee flag. The first hook of a family earns its
//   scout a Species specimen. Its parent in the Tree of Hooks is the earliest-seen family one ability away, else two
//   away, else none (a root). Checked: at most 15 + 105 reads, only when a family is new.
// Observed, ratings fixed at listing: complexity from the abilities (return deltas and a dynamic fee count double)
//   and code size; originality 100 for the first of a family, falling as the family fills, and 0 for a copy (a code
//   hash or stripped hash already listed for an older hook).
// Observed, challengers: anyone may prove a later hook is a near-copy of an earlier one: identical code apart from
//   ranges the challenger names, together at most 1% of the code (at least 64 bytes allowed for constructor values).
//   A proven copy's originality falls to 0 and its scout's deposit, if still held, goes to the challenger.
// Observed: an unchallenged deposit can be taken back after 7 days. A listing stays either way.
// Limit, stated: originality only catches copies that kept the code's shape; a rewritten copy reads as new.
// Limit, stated: only pools with native ETH as the first currency are put in the lens' view (the others are listed,
//   profiled and placed in the Tree, but never rated for life).

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ISpecimens} from "./Interfaces.sol";

interface ILensTrack {
    function track(uint32 ref) external returns (bool);
    function demote(uint32 ref) external;
}

contract FieldGuide {
    using PoolIdLibrary for PoolKey;

    uint256 public constant DEPOSIT = 0.002 ether;
    uint256 public constant HOLD = 7 days;
    uint256 public constant MIN_MASK = 64;
    uint24 internal constant DYNAMIC_FEE = 0x800000;
    uint8 internal constant KIND_SPECIES = 2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    IPoolManager public immutable MANAGER;
    address public immutable SPROUT;
    address public lens;
    ISpecimens public specimens;
    bool public bound;

    struct Entry {
        bytes32 poolId;
        address hook;
        uint40 at;
        uint16 family; // 14 ability bits | dynamic fee << 14
        uint8 mask; // the six Nookleus trait families it carries
        uint8 complexity; // 0..100
        uint8 originality; // 0..100
        uint8 currencyClass; // 0 native ETH, 1 dollar stable, 2 other
        bool copy;
        address scout;
        uint24 fee;
        int24 spacing;
        uint32 codeSize;
        bool depositHeld;
        bool tracked;
    }

    struct Family {
        uint32 firstRef;
        uint40 at;
        uint16 parent; // the family's parent in the Tree of Hooks (0 = a root, or family 0 itself)
        bool rooted; // true when it has no parent
        uint32 count;
    }

    Entry[] internal entries; // ref = index + 1
    mapping(bytes32 => uint32) public refOfPool;
    mapping(bytes32 => uint32) public firstWithCode; // code hash => first ref
    mapping(bytes32 => uint32) public firstWithStripped; // stripped hash => first ref
    mapping(uint16 => Family) public families;
    uint32 public familyCount;
    uint256 public depositsHeld;

    event Listed(uint32 indexed ref, address indexed scout, bytes32 indexed poolId, address hook, uint16 family, bool copy);
    event NewFamily(uint16 indexed family, uint16 parent, bool rooted, uint32 ref);
    event Contested(uint32 indexed ref, uint32 indexed original, address indexed challenger, uint256 deposit);
    event Retrieved(uint32 indexed ref, address indexed scout);

    error NotSprout();
    error AlreadyBound();
    error WrongDeposit();
    error NoPool();
    error NoCode();
    error Listed_();
    error NotOlder();
    error SizeDiffers();
    error MaskTooWide();
    error Differs(uint256 at);
    error AlreadyCopy();
    error TooSoon();
    error NotYours();
    error Nothing();
    error SendFailed();

    constructor(IPoolManager manager, address sprout) {
        MANAGER = manager;
        SPROUT = sprout;
    }

    function bind(address lens_, ISpecimens specimens_) external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (bound) revert AlreadyBound();
        bound = true;
        lens = lens_;
        specimens = specimens_;
    }

    // ------------------------------------------------------------------------------------------------ listing

    function list(PoolKey calldata key) external payable returns (uint32 ref) {
        if (msg.value != DEPOSIT) revert WrongDeposit();
        bytes32 id = PoolId.unwrap(key.toId());
        if (refOfPool[id] != 0) revert Listed_();
        if (uint256(MANAGER.extsload(keccak256(abi.encode(id, uint256(6))))) == 0) revert NoPool();
        address hook = address(key.hooks);
        uint256 size = hook.code.length;
        if (size == 0) revert NoCode();

        Entry memory e;
        e.poolId = id;
        e.hook = hook;
        e.at = uint40(block.timestamp);
        e.scout = msg.sender;
        e.fee = key.fee;
        e.spacing = key.tickSpacing;
        e.codeSize = uint32(size);
        e.depositHeld = true;
        uint16 abilities = uint16(uint160(hook) & 0x3fff);
        bool dynamic = key.fee == DYNAMIC_FEE;
        e.family = abilities | (dynamic ? uint16(1 << 14) : 0);
        e.mask = _mask(abilities, dynamic);
        e.complexity = _complexity(abilities, dynamic, size);
        e.currencyClass = _class(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));

        entries.push(e);
        ref = uint32(entries.length);
        refOfPool[id] = ref;
        depositsHeld += DEPOSIT;

        // copies: the same code (or the same code without its metadata trailer) under an older hook address
        bytes32 h = hook.codehash;
        bytes32 st = _stripped(hook, size);
        uint32 a = firstWithCode[h];
        uint32 b = firstWithStripped[st];
        bool copy = (a != 0 && entries[a - 1].hook != hook) || (b != 0 && entries[b - 1].hook != hook);
        if (a == 0) firstWithCode[h] = ref;
        if (b == 0) firstWithStripped[st] = ref;

        Family storage fam = families[e.family];
        bool isNew = fam.count == 0 && fam.firstRef == 0;
        if (isNew) {
            (uint16 parent, bool rooted) = _parent(e.family);
            fam.firstRef = ref;
            fam.at = uint40(block.timestamp);
            fam.parent = parent;
            fam.rooted = rooted;
            familyCount += 1;
            emit NewFamily(e.family, parent, rooted, ref);
        }
        fam.count += 1;
        Entry storage es = entries[ref - 1];
        es.copy = copy;
        es.originality = copy ? 0 : uint8(400 / (3 + fam.count)); // 100 for the first, 66, 50, 40 ...
        if (isNew && !copy && address(specimens) != address(0)) {
            specimens.mint(msg.sender, KIND_SPECIES, (uint256(e.family) << 32) | ref);
        }
        if (Currency.unwrap(key.currency0) == address(0) && lens != address(0)) {
            es.tracked = ILensTrack(lens).track(ref);
        }
        emit Listed(ref, msg.sender, id, hook, e.family, copy);
    }

    function _mask(uint16 ab, bool dynamic) internal pure returns (uint8 m) {
        if (dynamic) m |= 1; // dynamic fees
        if (ab & 0x80 != 0) m |= 2; // acts before swaps
        if (ab & 0x40 != 0) m |= 4; // acts after swaps
        if (ab & 0x08 != 0) m |= 8; // custom pricing
        if (ab & 0xf03 != 0) m |= 16; // liquidity rules
        if (ab & 0x30 != 0) m |= 32; // donations
    }

    function _complexity(uint16 ab, bool dynamic, uint256 size) internal pure returns (uint8) {
        uint256 c;
        for (uint256 i; i < 14; ++i) if ((ab >> i) & 1 == 1) c += i < 4 ? 2 : 1; // bits 0..3 are return deltas
        if (dynamic) c += 2;
        if (size >= 8192) c += 1;
        if (size >= 16384) c += 1;
        // most possible: 10 + 8 + 2 + 2 = 22
        return uint8((c * 100) / 22);
    }

    function _class(address c0, address c1) internal pure returns (uint8) {
        if (c0 == address(0)) return 0;
        if (c0 == USDC || c1 == USDC || c0 == USDT || c1 == USDT || c0 == DAI || c1 == DAI) return 1;
        return 2;
    }

    function _stripped(address hook, uint256 size) internal view returns (bytes32 h) {
        bytes memory code = hook.code;
        uint256 keep = size;
        if (size > 2) {
            uint256 meta = (uint256(uint8(code[size - 2])) << 8) | uint256(uint8(code[size - 1]));
            if (meta + 2 < size && meta < 256) {
                uint8 head = uint8(code[size - meta - 2]);
                if (head >= 0xa1 && head <= 0xa3) keep = size - meta - 2;
            }
        }
        assembly {
            h := keccak256(add(code, 32), keep)
        }
    }

    /// @dev The earliest-seen listed family one ability away, else two away; none means a root.
    function _parent(uint16 fam) internal view returns (uint16 parent, bool rooted) {
        uint40 best = type(uint40).max;
        for (uint256 i; i < 15; ++i) {
            Family memory f = families[fam ^ uint16(1 << i)];
            if (f.firstRef != 0 && f.at < best) {
                best = f.at;
                parent = fam ^ uint16(1 << i);
            }
        }
        if (best != type(uint40).max) return (parent, false);
        for (uint256 i; i < 15; ++i) {
            for (uint256 j = i + 1; j < 15; ++j) {
                uint16 c = fam ^ uint16(1 << i) ^ uint16(1 << j);
                Family memory f = families[c];
                if (f.firstRef != 0 && f.at < best) {
                    best = f.at;
                    parent = c;
                }
            }
        }
        if (best != type(uint40).max) return (parent, false);
        return (0, true);
    }

    // ------------------------------------------------------------------------------------------------ challengers

    /// @notice Prove `ref`'s hook is a near-copy of `original`'s (listed earlier): equal code except inside the given
    ///         [start, end) byte ranges, ascending and apart, together at most 1% of the code (64 bytes at least).
    function contest(uint32 ref, uint32 original, uint256[] calldata ranges) external returns (uint256 award) {
        Entry storage e = entries[ref - 1];
        Entry storage o = entries[original - 1];
        if (o.at > e.at || original >= ref) revert NotOlder();
        if (e.copy) revert AlreadyCopy();
        bytes memory a = e.hook.code;
        bytes memory b = o.hook.code;
        if (a.length != b.length) revert SizeDiffers();
        uint256 allowed = a.length / 100 > MIN_MASK ? a.length / 100 : MIN_MASK;
        uint256 masked;
        uint256 cursor;
        for (uint256 k; k + 1 < ranges.length; k += 2) {
            uint256 start = ranges[k];
            uint256 end = ranges[k + 1];
            if (start < cursor || end < start || end > a.length) revert MaskTooWide();
            _same(a, b, cursor, start);
            masked += end - start;
            cursor = end;
        }
        if (masked > allowed) revert MaskTooWide();
        _same(a, b, cursor, a.length);
        e.copy = true;
        e.originality = 0;
        if (e.tracked) ILensTrack(lens).demote(ref);
        if (e.depositHeld) {
            e.depositHeld = false;
            depositsHeld -= DEPOSIT;
            award = DEPOSIT;
            (bool ok,) = msg.sender.call{value: DEPOSIT}("");
            if (!ok) revert SendFailed();
        }
        emit Contested(ref, original, msg.sender, award);
    }

    function _same(bytes memory a, bytes memory b, uint256 from, uint256 to) internal pure {
        uint256 i = from;
        for (; i + 32 <= to; i += 32) {
            bytes32 x;
            bytes32 y;
            assembly {
                x := mload(add(add(a, 32), i))
                y := mload(add(add(b, 32), i))
            }
            if (x != y) revert Differs(i);
        }
        for (; i < to; ++i) if (a[i] != b[i]) revert Differs(i);
    }

    /// @notice Ask the lens to take a listed ETH pool into view (a listing made while the view was full). Anyone.
    function retrack(uint32 ref) external returns (bool ok) {
        Entry storage e = entries[ref - 1];
        if (e.tracked || e.currencyClass != 0) return e.tracked;
        ok = ILensTrack(lens).track(ref);
        e.tracked = ok;
    }

    /// @notice The scout takes the deposit back, 7 days after listing, if no challenger took it.
    function retrieve(uint32 ref) external {
        Entry storage e = entries[ref - 1];
        if (e.scout != msg.sender) revert NotYours();
        if (block.timestamp < uint256(e.at) + HOLD) revert TooSoon();
        if (!e.depositHeld) revert Nothing();
        e.depositHeld = false;
        depositsHeld -= DEPOSIT;
        (bool ok,) = msg.sender.call{value: DEPOSIT}("");
        if (!ok) revert SendFailed();
        emit Retrieved(ref, msg.sender);
    }

    // ------------------------------------------------------------------------------------------------ views

    function entry(uint32 ref) external view returns (Entry memory) {
        return entries[ref - 1];
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    function entryForLens(uint32 ref) external view returns (bytes32, int24, uint8, uint8, uint8) {
        Entry storage e = entries[ref - 1];
        return (e.poolId, e.spacing, e.mask, e.originality, e.complexity);
    }

    function familiesOf(uint32 ref) external view returns (uint8 mask, bool listed) {
        if (ref == 0 || ref > entries.length) return (0, false);
        return (entries[ref - 1].mask, true);
    }

    function scoutOf(uint32 ref) external view returns (address) {
        return entries[ref - 1].scout;
    }
}
