// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal CreateX interface (https://github.com/pcaversaccio/createx) used for CREATE3 deployments.
interface ICreateX {
    /// @dev `salt` is the raw (unguarded) salt; CreateX guards it with msg.sender / chainid per its layout.
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @dev `salt` must be the already-guarded salt. Uses CreateX itself as the deployer.
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}
