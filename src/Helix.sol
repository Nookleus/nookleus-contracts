// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 2: THE HELIX (the brain and the clock)
//
// Observed, the signal for each of the six trait families: how much more of the ecosystem's measured life the
//   family carries than its plain share of tracked pools (the lens), 60% over the last day and 40% over the last
//   week; blended half and half with what Nookleus' own traders pledged (fee-weighted, see the nucleus) when any did.
// Observed, the target level of the matching strand: 4 + 16 x signal, held to 0..8. It only counts past a level
//   boundary by a quarter of a level, never inside a 0.03 dead band, and only after two evaluations in a row want
//   the same direction. Replayed on a real week of mainnet v4 data: about 3.5 steps a day per species and
//   no step undone inside 6 hours.
// Observed, the clock: the first pulse at or after :45 of an hour previews one step per species (a strand, one level
//   up or down), picked with odds proportional to how far each strand sits from its target, the hour's entropy
//   deciding. The first pulse in the next hour applies it. At most one step per species per hour; a strand dropped
//   to 0 cannot return for 6 hours. Nobody pulsing means the hour is skipped, not stacked.
// Observed: once a week (Wednesday 12:00 UTC preview) the step is an experiment: the rare family (under 10% of
//   tracked pools) growing fastest gets +1 for its strand, if it can.
// Observed: SPORES releases. At the first pulse of each UTC day, as many random hours as the SPORES level are drawn;
//   in those hours the nucleus may release the spore pot to every holder.
// Observed: mutation calls. A caller whose prediction (made in a trade or for free, before :45) matches the step
//   previewed that hour earns a point; the first to claim a step that put a strand at a level never seen before
//   on that species receives its Trait specimen. Every 30 days a season closes: the lens re-weights its paper index
//   and Almanac specimens go to the leading caller and the leading observer.
// Limit, stated: the entropy is block.prevrandao and the previous block hash; a block proposer can nudge which
//   strand moves. No money depends on the pick beyond one bounded step.

import {INucleus, ILens, ISpecimens} from "./Interfaces.sol";

interface ILensSeason {
    function reseason() external;
    function leadingObserver() external view returns (address);
}

contract Helix {
    uint256 internal constant HOUR = 3600;
    uint256 public constant PREVIEW_AT = 2700;
    uint256 public constant COOLDOWN = 6 hours;
    uint256 public constant SEASON = 30 days;
    uint256 public constant EXPERIMENT_HOUR_OF_WEEK = 156; // hour 0 of a week is Thursday 00:00 UTC; 156 = Wednesday 12:00
    int256 internal constant ONE = 1e18;
    int256 public constant GAIN = 16;
    int256 public constant START = 4;
    int256 public constant LEVELS = 8;
    int256 public constant HYST = 0.25e18;
    int256 public constant DEAD_BAND = 0.03e18;
    int256 public constant MIX_SHORT = 0.6e18;
    int8 public constant PERSIST = 2;
    uint256 public constant RARE = 0.1e18;

    uint8 internal constant KIND_TRAIT = 1;
    uint8 internal constant KIND_ALMANAC = 3;

    INucleus public immutable NUCLEUS;
    address public immutable SPROUT;
    ILens public lens;
    ISpecimens public specimens;
    uint64 public bornAt;
    bool public bound;

    struct Plan {
        uint32 hour; // applies at the start of this hour
        uint8 strand;
        uint8 level;
        bool experiment;
        bool set;
    }

    mapping(uint256 => Plan) public plan;
    mapping(uint256 => uint32) public evaluatedHour;
    mapping(uint256 => uint256) internal seen; // six int8 persistence counters
    mapping(uint256 => uint256) internal dropped; // six uint40 drop times
    mapping(uint256 => uint64) internal levelsSeen; // bit strand * 9 + level: reached at least once
    mapping(uint32 => uint16) public stepAt; // preview hour => code per species (8 bits each)
    mapping(uint32 => uint8) public traitOpen; // preview hour => species bits whose step is a first-time level
    mapping(uint256 => mapping(uint32 => uint32)) public sporeMask; // species => UTC day => hour bits
    mapping(address => uint32) public scoredHour;
    mapping(address => uint32) public points;
    address[10] public leaders;
    uint32 public day;
    uint32 public season;
    uint16[2] public stepsToday;

    event Bound(address lens, address specimens);
    event Preview(uint256 indexed species, uint32 indexed hour, uint8 strand, uint8 from, uint8 to, bool experiment);
    event Held(uint256 indexed species, uint32 indexed hour);
    event Mutated(uint256 indexed species, uint32 indexed hour, uint8 strand, uint8 from, uint8 to, bool experiment);
    event Daily(uint32 indexed day, uint16 steps0, uint16 steps1);
    event SporesDrawn(uint256 indexed species, uint32 indexed day, uint32 hourMask);
    event Scored(address indexed caller, uint32 indexed hour, uint32 points);
    event Season(uint32 indexed season, address caller, address observer);
    event IndexSkipped(uint32 indexed season);

    error NotSprout();
    error AlreadyBound();
    error NotDue();
    error Missed();
    error Scored_();

    constructor(INucleus nucleus, address sprout) {
        NUCLEUS = nucleus;
        SPROUT = sprout;
    }

    function bind(ILens lens_, ISpecimens specimens_) external {
        if (msg.sender != SPROUT) revert NotSprout();
        if (bound) revert AlreadyBound();
        bound = true;
        lens = lens_;
        specimens = specimens_;
        bornAt = uint64(block.timestamp);
        day = uint32(block.timestamp / 1 days);
        // the starting levels count as seen: only a level a strand never held before earns a Trait specimen
        uint256 n = NUCLEUS.speciesCount();
        for (uint256 s; s < n; ++s) {
            uint8[6] memory lv = NUCLEUS.strandsOf(s);
            for (uint256 f; f < 6; ++f) levelsSeen[s] |= uint64(uint256(1) << (f * 9 + lv[f]));
        }
        emit Bound(address(lens_), address(specimens_));
    }

    // ------------------------------------------------------------------------------------------------ the pulse

    /// @notice Apply any step that is due, preview the next one after :45, and keep the calendar. Anyone may call;
    ///         the nucleus calls it on the first trade after it falls due.
    function pulse() external returns (uint64 nextAt) {
        uint256 t = block.timestamp;
        uint32 hour = uint32(t / HOUR);
        uint256 n = NUCLEUS.speciesCount();
        _calendar(t, n);
        for (uint256 s; s < n; ++s) {
            Plan memory p = plan[s];
            if (p.set && hour >= p.hour) _apply(s, p, t);
            if (t % HOUR >= PREVIEW_AT && evaluatedHour[s] != hour && bound) _evaluate(s, hour, t);
        }
        nextAt = nextDue();
    }

    /// @notice When the next pulse has work: a planned step's hour, or the next :45 not yet evaluated.
    function nextDue() public view returns (uint64 at) {
        uint256 t = block.timestamp;
        uint256 hour = t / HOUR;
        at = type(uint64).max;
        uint256 n = NUCLEUS.speciesCount();
        for (uint256 s; s < n; ++s) {
            Plan memory p = plan[s];
            if (p.set && p.hour * HOUR < at) at = uint64(p.hour * HOUR);
            uint256 next = evaluatedHour[s] == hour ? (hour + 1) * HOUR + PREVIEW_AT : hour * HOUR + PREVIEW_AT;
            if (next < at) at = uint64(next);
        }
        // the calendar (daily spores, seasons) needs a pulse each new day
        uint256 tomorrow = (t / 1 days + 1) * 1 days;
        if (tomorrow < at) at = uint64(tomorrow);
    }

    function _apply(uint256 s, Plan memory p, uint256 t) internal {
        uint8[6] memory lv = NUCLEUS.strandsOf(s);
        uint8 from = lv[p.strand];
        lv[p.strand] = p.level;
        delete plan[s];
        if (p.level == 0) {
            uint256 d = dropped[s];
            uint256 sh = 40 * uint256(p.strand);
            d = (d & ~(uint256(type(uint40).max) << sh)) | (t << sh);
            dropped[s] = d;
        }
        uint32 previewHour = p.hour - 1;
        uint8 code = uint8(0x80 | (s << 4) | (uint256(p.strand) << 1) | (p.level > from ? 1 : 0));
        stepAt[previewHour] |= uint16(uint256(code) << (8 * s));
        uint64 bit = uint64(uint256(1) << (uint256(p.strand) * 9 + p.level));
        if (levelsSeen[s] & bit == 0) {
            levelsSeen[s] |= bit;
            traitOpen[previewHour] |= uint8(1 << s);
        }
        if (s < 2) stepsToday[s] += 1;
        NUCLEUS.setStrands(s, lv, 0);
        emit Mutated(s, p.hour, p.strand, from, p.level, p.experiment);
    }

    // ------------------------------------------------------------------------------------------------ the brain

    function _evaluate(uint256 s, uint32 hour, uint256 t) internal {
        evaluatedHour[s] = hour;
        uint8[6] memory lv = NUCLEUS.strandsOf(s);
        int256[6] memory sig = signals(s);
        uint256 seenW = seen[s];
        uint256 dropW = dropped[s];
        uint256[6] memory weight;
        int8[6] memory dir;
        uint256 sum;
        for (uint256 f; f < 6; ++f) {
            (int8 want, uint256 w) = _want(sig[f], lv[f]);
            int8 c = int8(uint8(seenW >> (8 * f)));
            if (want == 0) c = 0;
            else if ((c > 0) == (want > 0) && c != 0) {
                if (c < 100 && c > -100) c += want;
            } else {
                c = want;
            }
            seenW = (seenW & ~(uint256(0xff) << (8 * f))) | (uint256(uint8(c)) << (8 * f));
            if (want == 0 || (c < PERSIST && c > -PERSIST)) continue;
            if (want > 0 && lv[f] == 0 && t < ((dropW >> (40 * f)) & type(uint40).max) + COOLDOWN) continue;
            weight[f] = w;
            dir[f] = want;
            sum += w;
        }
        seen[s] = seenW;

        if ((hour % 168) == EXPERIMENT_HOUR_OF_WEEK) {
            (bool ok, uint8 f) = _rareRising(lv, dropW, t);
            if (ok) {
                _preview(s, hour, f, lv[f], lv[f] + 1, true);
                return;
            }
        }
        if (sum == 0) {
            emit Held(s, hour + 1);
            return;
        }
        uint256 e = uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), hour, s))) % sum;
        for (uint256 f; f < 6; ++f) {
            if (weight[f] == 0) continue;
            if (e < weight[f]) {
                _preview(s, hour, uint8(f), lv[f], dir[f] > 0 ? lv[f] + 1 : lv[f] - 1, false);
                return;
            }
            e -= weight[f];
        }
    }

    function _preview(uint256 s, uint32 hour, uint8 f, uint8 from, uint8 to, bool experiment) internal {
        plan[s] = Plan(hour + 1, f, to, experiment, true);
        emit Preview(s, hour + 1, f, from, to, experiment);
    }

    /// @notice The six family signals for a species, 1e18 = one whole share.
    function signals(uint256 s) public view returns (int256[6] memory sig) {
        uint256[4][6] memory sh = lens.familyShares();
        uint256[6] memory pl = NUCLEUS.pledgesOf(s);
        uint256 sumP;
        for (uint256 f; f < 6; ++f) sumP += pl[f];
        for (uint256 f; f < 6; ++f) {
            int256 brain = (MIX_SHORT * (int256(sh[f][0]) - int256(sh[f][1])) + (ONE - MIX_SHORT) * (int256(sh[f][2]) - int256(sh[f][3]))) / ONE;
            if (sumP == 0) {
                sig[f] = brain;
            } else {
                int256 pledged = int256((pl[f] * 1e18) / sumP) - ONE / 6;
                sig[f] = (brain + pledged) / 2;
            }
        }
    }

    /// @dev Direction a strand wants (-1, 0, +1) and how far it is from its target, in 1e18 levels.
    function _want(int256 sig, uint8 level) internal pure returns (int8 want, uint256 gap) {
        if (sig < DEAD_BAND && sig > -DEAD_BAND) return (0, 0);
        int256 x = START * ONE + GAIN * sig;
        if (x < 0) x = 0;
        if (x > LEVELS * ONE) x = LEVELS * ONE;
        int256 l = int256(uint256(level)) * ONE;
        if (x >= l + ONE / 2 + HYST && level < uint8(uint256(LEVELS))) return (1, uint256(x - l));
        if (x <= l - ONE / 2 - HYST && level > 0) return (-1, uint256(l - x));
        return (0, 0);
    }

    function _rareRising(uint8[6] memory lv, uint256 dropW, uint256 t) internal view returns (bool ok, uint8 best) {
        uint256[4][6] memory sh = lens.familyShares();
        uint256 bestRatio;
        for (uint256 f; f < 6; ++f) {
            if (sh[f][3] >= RARE || lv[f] >= uint8(uint256(LEVELS))) continue;
            if (lv[f] == 0 && t < ((dropW >> (40 * f)) & type(uint40).max) + COOLDOWN) continue;
            (uint256 shortRate, uint256 longRate) = lens.growthOf(f);
            if (shortRate == 0) continue;
            uint256 ratio = longRate == 0 ? type(uint128).max : (shortRate * 1e18) / longRate;
            if (ratio > bestRatio) {
                bestRatio = ratio;
                best = uint8(f);
                ok = true;
            }
        }
    }

    // ------------------------------------------------------------------------------------------------ the calendar

    function _calendar(uint256 t, uint256 n) internal {
        uint32 d = uint32(t / 1 days);
        if (d != day && bound) {
            emit Daily(day, stepsToday[0], stepsToday[1]);
            day = d;
            stepsToday[0] = 0;
            stepsToday[1] = 0;
            for (uint256 s; s < n; ++s) {
                uint256 k = NUCLEUS.strandsOf(s)[5]; // SPORES level = releases today
                uint32 mask;
                uint256 e = uint256(keccak256(abi.encode(block.prevrandao, d, s)));
                for (uint256 i; i < k; ++i) {
                    // draw distinct hours; collisions take the next free hour
                    uint256 h = (e >> (8 * i)) % 24;
                    while ((mask >> h) & 1 == 1) h = (h + 1) % 24;
                    mask |= uint32(1 << h);
                }
                sporeMask[s][d] = mask;
                emit SporesDrawn(s, d, mask);
            }
        }
        // the season (about 0.55M gas) does not land on a trader unless nobody else closed it for a day
        uint256 due = bornAt + SEASON * (uint256(season) + 1);
        if (bound && t >= due && (msg.sender != address(NUCLEUS) || t >= due + 1 days)) {
            season += 1;
            // read before reseason(): it starts the next observer season (and clears the leader)
            address observer = ILensSeason(address(lens)).leadingObserver();
            // the paper index re-weighting is best effort: a failure there never stops the clock
            try ILensSeason(address(lens)).reseason() {} catch {
                emit IndexSkipped(season);
            }
            address caller = leaders[0];
            if (caller != address(0)) specimens.mint(caller, KIND_ALMANAC, (uint256(season) << 8) | 1);
            if (observer != address(0)) specimens.mint(observer, KIND_ALMANAC, (uint256(season) << 8) | 2);
            emit Season(season, caller, observer);
        }
    }

    /// @notice Is this hour one of today's spore hours for a species?
    function sporeHour(uint256 s) external view returns (bool) {
        uint256 hour = block.timestamp / HOUR;
        return (sporeMask[s][uint32(hour / 24)] >> (hour % 24)) & 1 == 1;
    }

    // ------------------------------------------------------------------------------------------------ calls

    /// @notice Claim your point for a correct mutation call (and the Trait specimen, if you are the first to claim a
    ///         step that reached a new level).
    function score() external returns (uint32 total) {
        (uint32 h, uint8 code) = NUCLEUS.callOf(msg.sender);
        if (h <= scoredHour[msg.sender]) revert Scored_();
        if (block.timestamp < (uint256(h) + 1) * HOUR) revert NotDue();
        uint256 s = (code >> 4) & 0x7;
        if (uint8(stepAt[h] >> (8 * s)) != code) revert Missed();
        scoredHour[msg.sender] = h;
        total = ++points[msg.sender];
        _rank(msg.sender, total);
        if (traitOpen[h] & (1 << s) != 0) {
            traitOpen[h] &= ~uint8(1 << s);
            specimens.mint(msg.sender, KIND_TRAIT, (uint256(h) << 8) | code);
        }
        emit Scored(msg.sender, h, total);
    }

    function _rank(address who, uint32 pts) internal {
        // keep the ten best callers, best first (at most 10 reads and moves)
        uint256 at = 10;
        for (uint256 i; i < 10; ++i) {
            if (leaders[i] == who) {
                at = i;
                break;
            }
        }
        if (at == 10) {
            if (leaders[9] != address(0) && points[leaders[9]] >= pts) return;
            at = 9;
            leaders[9] = who;
        }
        while (at > 0 && points[leaders[at - 1]] < pts) {
            leaders[at] = leaders[at - 1];
            leaders[at - 1] = who;
            at--;
        }
    }
}
