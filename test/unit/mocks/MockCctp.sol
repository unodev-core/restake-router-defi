// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "./MockERC20.sol";

/// @notice CCTP V2 TokenMessenger: burns by pulling USDC to itself, mints by `MockERC20.mint`.
///         Mirrors the real checks the router relies on (amount, recipient, maxFee, fee ≤ maxFee).
contract MockTokenMessengerV2 {
    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
    }

    MockERC20 public immutable usdc;
    address public immutable localMessageTransmitter;
    address public immutable feeRecipient = address(0xFEE);
    Burn public lastBurn;
    uint256 public burns;

    constructor(MockERC20 usdc_, address transmitter_) {
        usdc = usdc_;
        localMessageTransmitter = transmitter_;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        require(amount > 0, "Amount must be nonzero");
        require(mintRecipient != bytes32(0), "Mint recipient must be nonzero");
        require(maxFee < amount, "Max fee must be less than amount");
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastBurn =
            Burn(amount, destinationDomain, mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold);
        ++burns;
    }

    /// @dev Called by the transmitter with the burn message body.
    function handleReceive(bytes calldata body) external returns (bool) {
        require(msg.sender == localMessageTransmitter, "Invalid message transmitter");
        address mintRecipient = address(uint160(uint256(bytes32(body[36:68]))));
        uint256 amount = uint256(bytes32(body[68:100]));
        uint256 maxFee = uint256(bytes32(body[132:164]));
        uint256 feeExecuted = uint256(bytes32(body[164:196]));
        require(feeExecuted == 0 || feeExecuted < amount, "Fee equals or exceeds amount");
        require(feeExecuted <= maxFee, "Fee exceeds max fee");
        // Only USDC burns mint USDC; anything else mints nothing here.
        if (address(uint160(uint256(bytes32(body[4:36])))) == address(usdc)) {
            usdc.mint(mintRecipient, amount - feeExecuted);
            if (feeExecuted != 0) usdc.mint(feeRecipient, feeExecuted);
        }
        return true;
    }
}

/// @notice CCTP V2 MessageTransmitter: no signatures, but enforces destination domain, destination caller and
///         nonce replay like the real one, then dispatches to `recipient`.
contract MockMessageTransmitterV2 {
    uint32 public immutable localDomain;
    mapping(bytes32 nonce => bool) public usedNonces;

    constructor(uint32 localDomain_) {
        localDomain = localDomain_;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        require(uint32(bytes4(message[8:12])) == localDomain, "Invalid destination domain");
        bytes32 destinationCaller = bytes32(message[108:140]);
        require(
            destinationCaller == bytes32(0) || destinationCaller == bytes32(uint256(uint160(msg.sender))),
            "Invalid caller for message"
        );
        bytes32 nonce = bytes32(message[12:44]);
        require(!usedNonces[nonce], "Nonce already used");
        usedNonces[nonce] = true;
        address recipient = address(uint160(uint256(bytes32(message[76:108]))));
        (bool ok, bytes memory ret) =
            recipient.call(abi.encodeWithSelector(MockTokenMessengerV2.handleReceive.selector, message[148:]));
        require(ok && abi.decode(ret, (bool)), "handleReceive failed");
        return true;
    }
}

/// @notice Stand-in for an arbitrary CCTP message recipient that returns success without minting anything.
contract MockFakeRecipient {
    function handleReceive(bytes calldata) external pure returns (bool) {
        return true;
    }
}
