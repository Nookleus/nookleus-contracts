// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · SPECIMEN 7: AMBER (the launch liquidity, preserved)
//
// Observed: the launch positions' NFTs live here forever. This contract can do exactly one thing with them: collect
//   their trading fees (a zero liquidity change) and send both currencies to OWNER. Anyone may pay the gas for it.
// Observed: there is no function that removes liquidity, transfers an NFT, or changes OWNER.

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IHeldBy {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract Amber {
    IPositionManager public immutable POSM;
    address public immutable OWNER;

    event Collected(uint256 indexed tokenId);

    error NotHeld();

    constructor(IPositionManager posm, address owner_) {
        POSM = posm;
        OWNER = owner_;
    }

    /// @notice Collect the fees of a held position to OWNER.
    function collect(uint256 tokenId) external {
        if (IHeldBy(address(POSM)).ownerOf(tokenId) != address(this)) revert NotHeld();
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(tokenId);
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, OWNER);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit Collected(tokenId);
    }
}
