// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 6: THE SPECIMEN DRAWER (collectibles, ERC-721)
//
// Observed, birth: deployed on its own, before the launch. Ethereum caps one transaction at 16,777,216 gas and the
//   launch graph with all nine specimens measured 24.9M, so four of them (helix, lens, field guide, drawer) are born
//   first and the launch names them. They know the launch only by SPROUT_CODEHASH, the code hash of the one sprout,
//   whose bytes carry Programmable's graph factory as their deployer: the first and only bind must come from a
//   contract with exactly that code. Nothing else can bind them, and nothing can bind them twice.
//
// Observed, three kinds, each minted only by a rule elsewhere, never sold:
//   Trait    the first caller to claim a step that took a strand to a level it never held (helix)
//   Species  the scout who listed the first hook of a new family (field guide)
//   Almanac  each season (30 days), the leading caller and the leading observer (helix): the monthly census plate
// Observed: metadata is written by this contract, on chain, from what the rule recorded. No owner, no royalty.
// Limit, stated: collectibles carry no claim on fees or anything else.

contract Specimens {
    string public constant name = "Nookleus Specimens";
    string public constant symbol = "NOOKSPEC";
    uint8 internal constant TRAIT = 1;
    uint8 internal constant SPECIES = 2;
    uint8 internal constant ALMANAC = 3;

    bytes32 public immutable SPROUT_CODEHASH; // the only code that may bind it, once
    address public guide;
    address public helix;
    bool public bound;

    struct Card {
        uint8 kind;
        uint64 at;
        uint256 detail;
    }

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => Card) public cards;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error NotSprout();
    error AlreadyBound();
    error NotMinter();
    error NotAllowed();
    error NoSuchCard();
    error BadReceiver();

    constructor(bytes32 sproutCodehash) {
        SPROUT_CODEHASH = sproutCodehash;
    }

    function bind(address guide_, address helix_) external {
        if (msg.sender.codehash != SPROUT_CODEHASH) revert NotSprout();
        if (bound) revert AlreadyBound();
        bound = true;
        guide = guide_;
        helix = helix_;
    }

    function mint(address to, uint8 kind, uint256 detail) external returns (uint256 id) {
        if (!((msg.sender == guide && kind == SPECIES) || (msg.sender == helix && (kind == TRAIT || kind == ALMANAC)))) {
            revert NotMinter();
        }
        id = ++totalSupply;
        cards[id] = Card(kind, uint64(block.timestamp), detail);
        ownerOf[id] = to;
        balanceOf[to] += 1;
        emit Transfer(address(0), to, id);
    }

    // ------------------------------------------------------------------------------------------------ ERC-721

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f;
    }

    function approve(address spender, uint256 id) external {
        address owner = ownerOf[id];
        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert NotAllowed();
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        if (ownerOf[id] != from || to == address(0)) revert NotAllowed();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender] && msg.sender != getApproved[id]) revert NotAllowed();
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
        ownerOf[id] = to;
        delete getApproved[id];
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x150b7a02, msg.sender, from, id, data));
            if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != bytes4(0x150b7a02)) revert BadReceiver();
        }
    }

    // ------------------------------------------------------------------------------------------------ metadata

    function tokenURI(uint256 id) external view returns (string memory) {
        Card memory c = cards[id];
        if (c.kind == 0) revert NoSuchCard();
        string memory kind = c.kind == TRAIT ? "Trait" : c.kind == SPECIES ? "Species" : "Almanac";
        string memory attrs;
        if (c.kind == TRAIT) {
            // detail = preview hour << 8 | step code (0x80 | species << 4 | strand << 1 | up)
            uint256 code = c.detail & 0xff;
            attrs = string.concat(
                '{"trait_type":"species","value":', _u((code >> 4) & 7), '},{"trait_type":"strand","value":"',
                _strand((code >> 1) & 7), '"},{"trait_type":"direction","value":"', code & 1 == 1 ? "up" : "down",
                '"},{"trait_type":"hour","value":', _u(c.detail >> 8), "}"
            );
        } else if (c.kind == SPECIES) {
            // detail = family << 32 | field guide reference
            attrs = string.concat(
                '{"trait_type":"family","value":', _u(c.detail >> 32), '},{"trait_type":"listing","value":', _u(c.detail & 0xffffffff), "}"
            );
        } else {
            // detail = season << 8 | role (1 caller, 2 observer)
            attrs = string.concat(
                '{"trait_type":"season","value":', _u(c.detail >> 8), '},{"trait_type":"role","value":"',
                c.detail & 0xff == 1 ? "caller" : "observer", '"}'
            );
        }
        return string.concat(
            'data:application/json;utf8,{"name":"Nookleus ', kind, " #", _u(id), '","description":"A Nookleus specimen, minted by rule.","attributes":[',
            attrs, "]}"
        );
    }

    function _strand(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "TEMPER";
        if (i == 1) return "KINSHIP";
        if (i == 2) return "NECTAR";
        if (i == 3) return "DIGEST";
        if (i == 4) return "ROOTS";
        return "SPORES";
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) b[--len] = bytes1(uint8(48 + (v % 10)));
        return string(b);
    }
}
