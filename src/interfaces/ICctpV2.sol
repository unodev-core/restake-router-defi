// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Minimal Circle CCTP V2 TokenMessengerV2 surface used by the router.
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    function localMessageTransmitter() external view returns (address);
}

/// @notice Minimal Circle CCTP V2 MessageTransmitterV2 surface used by the router.
interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool success);

    function localDomain() external view returns (uint32);
}
