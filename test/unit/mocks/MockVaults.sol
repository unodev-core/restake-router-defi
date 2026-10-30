// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IRestakeRouter} from "../../../src/interfaces/IRestakeRouter.sol";

/// @notice Plain OZ ERC-4626 with EIP-2612 permit on its shares. `decimalsOffset` 12 gives 18-decimal shares
///         over USDC, like Morpho / Sky sUSDC.
contract MockERC4626 is ERC4626, ERC20Permit {
    uint8 private immutable _offset;

    constructor(IERC20 asset_, uint8 decimalsOffset_)
        ERC20("Mock Vault", "mVLT")
        ERC4626(asset_)
        ERC20Permit("Mock Vault")
    {
        _offset = decimalsOffset_;
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _offset;
    }
}

/// @notice Mimics YO: without enough idle liquidity, `redeem` moves the shares into the vault, records a pending
///         request keyed by `receiver`, and returns 0.
contract MockAsyncRedeemVault is MockERC4626 {
    bool public instant = true;
    mapping(address receiver => uint256 shares) public pendingShares;

    constructor(IERC20 asset_) MockERC4626(asset_, 0) {}

    function setInstant(bool instant_) external {
        instant = instant_;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (instant) return super.redeem(shares, receiver, owner);
        require(msg.sender == owner, "owner only");
        _transfer(owner, address(this), shares);
        pendingShares[receiver] += shares;
        return 0;
    }
}

/// @notice Misbehaving vault: takes only half the approved assets on deposit, burns only half the shares on redeem.
contract MockLossyVault is MockERC4626 {
    constructor(IERC20 asset_) MockERC4626(asset_, 0) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return super.deposit(assets / 2, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        return super.redeem(shares / 2, receiver, owner);
    }
}

/// @notice Calls back into the router during `deposit` / `redeem` to probe the reentrancy guard.
contract MockReentrantVault is MockERC4626 {
    IRestakeRouter public router;
    bytes public reentryCall;

    constructor(IERC20 asset_) MockERC4626(asset_, 0) {}

    function arm(IRestakeRouter router_, bytes calldata call_) external {
        router = router_;
        reentryCall = call_;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _reenter();
        return super.deposit(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _reenter();
        return super.redeem(shares, receiver, owner);
    }

    function _reenter() private {
        if (address(router) == address(0)) return;
        (bool ok, bytes memory ret) = address(router).call(reentryCall);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
