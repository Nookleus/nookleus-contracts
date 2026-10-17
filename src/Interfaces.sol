// SPDX-License-Identifier: MIT
// links: site https://nookleus.xyz   x https://x.com/nookleuseth   github https://github.com/Nookleus
pragma solidity 0.8.26;

// NOOKLEUS · FIELD NOTES · THE WIRING BETWEEN SPECIMENS
// Each interface lists only what another Nookleus contract calls. Nothing here reaches another project's hook.

interface INookToken {
    function feed() external payable;
    function ageOf(address who) external view returns (uint256 age, uint256 balance);
    function burn(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function startedAt() external view returns (uint256);
}

interface INucleus {
    function strandsOf(uint256 species) external view returns (uint8[6] memory);
    function setStrands(uint256 species, uint8[6] calldata levels, uint64 nextPulseAt) external;
    function pledgesOf(uint256 species) external view returns (uint256[6] memory);
    function speciesCount() external view returns (uint256);
    function poolIdOf(uint256 species) external view returns (bytes32);
    function callOf(address caller) external view returns (uint32 hour, uint8 code);
}

interface IHelix {
    function pulse() external returns (uint64 nextPulseAt);
    function sporeHour(uint256 species) external view returns (bool);
}

interface ILens {
    /// per family f: [short weighted share, short plain share, long weighted share, long plain share], 1e18 = 100%
    function familyShares() external view returns (uint256[4][6] memory);
    function growthOf(uint256 family) external view returns (uint256 shortRate, uint256 longRate);
}

interface IFieldGuide {
    function familiesOf(uint32 ref) external view returns (uint8 mask, bool listed);
    function scoutOf(uint32 ref) external view returns (address);
}

interface ISpecimens {
    function mint(address to, uint8 kind, uint256 detail) external returns (uint256 id);
}
