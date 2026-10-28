// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAaveV3Pool} from "../../../src/interfaces/IAaveV3Pool.sol";

/// @dev Aave WadRayMath, half-up rounding.
library RayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }
}

/// @notice Scaled-balance aToken: balances rebase with the pool's liquidity index, and transfers can be off by
///         1 wei from the requested amount, like the real thing.
contract MockAToken {
    using RayMath for uint256;

    string public constant name = "Mock aUSDC";
    string public constant symbol = "maUSDC";
    uint8 public constant decimals = 6;

    address public immutable UNDERLYING_ASSET_ADDRESS;
    MockAavePool public immutable POOL;

    mapping(address => uint256) public scaledBalanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public scaledTotalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address underlying_, MockAavePool pool_) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
        POOL = pool_;
    }

    modifier onlyPool() {
        require(msg.sender == address(POOL), "pool only");
        _;
    }

    function balanceOf(address account) public view returns (uint256) {
        return scaledBalanceOf[account].rayMul(POOL.liquidityIndex());
    }

    function totalSupply() external view returns (uint256) {
        return scaledTotalSupply.rayMul(POOL.liquidityIndex());
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyPool {
        uint256 scaled = amount.rayDiv(POOL.liquidityIndex());
        scaledBalanceOf[to] += scaled;
        scaledTotalSupply += scaled;
        emit Transfer(address(0), to, amount);
    }

    /// @dev Burns the whole position when `amount` is the full balance, so no scaled dust is left behind.
    function burn(address from, address to, uint256 amount) external onlyPool {
        uint256 scaled = amount == balanceOf(from) ? scaledBalanceOf[from] : amount.rayDiv(POOL.liquidityIndex());
        scaledBalanceOf[from] -= scaled;
        scaledTotalSupply -= scaled;
        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 scaled = amount.rayDiv(POOL.liquidityIndex());
        scaledBalanceOf[from] -= scaled;
        scaledBalanceOf[to] += scaled;
        emit Transfer(from, to, amount);
    }
}

contract MockAavePool {
    uint256 public liquidityIndex = RayMath.RAY;
    mapping(address asset => address aToken) public aTokenOf;

    function listReserve(address asset, address aToken) external {
        aTokenOf[asset] = aToken;
    }

    /// @dev The test must also fund the aToken with underlying to back the accrued interest.
    function setLiquidityIndex(uint256 index) external {
        liquidityIndex = index;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        address aToken = aTokenOf[asset];
        IERC20(asset).transferFrom(msg.sender, aToken, amount);
        MockAToken(aToken).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken aToken = MockAToken(aTokenOf[asset]);
        uint256 balance = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max) amount = balance;
        require(amount != 0 && amount <= balance, "invalid amount");
        aToken.burn(msg.sender, to, amount);
        return amount;
    }

    function getReserveData(address asset) external view returns (IAaveV3Pool.ReserveData memory data) {
        data.liquidityIndex = uint128(liquidityIndex);
        data.aTokenAddress = aTokenOf[asset];
    }
}
