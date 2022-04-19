// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import {ArrakisVaultV2Storage} from "./abstract/ArrakisVaultV2Storage.sol";
import {
    IERC20,
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    EnumerableSet
} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FullMath} from "./vendor/uniswap/FullMath.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

contract ArrakisVaultV2 is ArrakisVaultV2Storage {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct RebalanceParams {
        address[] withdrawTargets;
        bytes[] withdrawPayloads;
        address[] approvalTargets;
        uint256[] approveAmounts0;
        uint256[] approveAmounts1;
        address[] depositTargets;
        bytes[] depositPayloads;
    }

    event Minted(
        address receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In
    );

    event Burned(
        address receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out
    );

    event Rebalance(); // TODO:

    event ManagerWithdrawal(uint256 amount0, uint256 amount1);

    // User functions

    /// @notice mint ArrakisVaultV2 Shares by supplying underlying assets
    /// @dev to compute the amouint of tokens necessary to mint `mintAmount` see getMintAmounts
    /// @param mintAmount number of shares to mint
    /// @param receiver account to receive the minted shares
    /// @return amount0 amount of token0 transferred from msg.sender to mint `mintAmount`
    /// @return amount1 amount of token1 transferred from msg.sender to mint `mintAmount`
    // solhint-disable-next-line function-max-lines, code-complexity
    function mint(uint256 mintAmount, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(mintAmount > 0, "ArrakisVaultV2: mint 0");

        uint256 totalSupply = totalSupply();

        if (totalSupply > 0) {
            (uint256 amount0Current, uint256 amount1Current) =
                underlyingBalances();

            amount0 = FullMath.mulDivRoundingUp(
                amount0Current,
                mintAmount,
                totalSupply
            );
            amount1 = FullMath.mulDivRoundingUp(
                amount1Current,
                mintAmount,
                totalSupply
            );
        // solhint-disable-next-line no-empty-blocks
        } else {
            // TODO: if supply is 0 what do we do ?
        }

        // transfer amounts owed to contract
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        uint256 proportion = FullMath.mulDiv(1 ether, mintAmount, totalSupply);
        for (uint256 i = 0; i < _strategies.length(); i++) {
            address _strategy = _strategies.at(i);
            (uint256 in0, uint256 in1) =
                IStrategy(_strategy).depositAmounts(proportion);
            token0.safeIncreaseAllowance(_strategy, in0);
            token1.safeIncreaseAllowance(_strategy, in1);
            IStrategy(_strategies.at(i)).deposit(proportion);
        }

        _mint(receiver, mintAmount);
        emit Minted(receiver, mintAmount, amount0, amount1);
    }

    /// @notice burn ArrakisVaultV2 Shares and receive underlying assets
    /// @param burnAmount number of shares to burn
    /// @param receiver account to receive the underlying amounts of token0 and token1
    /// @return amount0 amount of token0 transferred to receiver for burning `burnAmount`
    /// @return amount1 amount of token1 transferred to receiver for burning `burnAmount`
    // solhint-disable-next-line function-max-lines
    function burn(uint256 burnAmount, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(burnAmount > 0, "ArrakisVaultV2: burn 0");

        uint256 totalSupply = totalSupply();
        amount0 = FullMath.mulDiv(
            token0.balanceOf(address(this)),
            burnAmount,
            totalSupply
        );
        amount1 = FullMath.mulDiv(
            token1.balanceOf(address(this)),
            burnAmount,
            totalSupply
        );
        uint256 proportion = FullMath.mulDiv(1 ether, burnAmount, totalSupply);
        _burn(msg.sender, burnAmount);
        for (uint256 i = 0; i < _strategies.length(); i++) {
            (uint256 credit0, uint256 credit1) =
                IStrategy(_strategies.at(i)).withdraw(proportion);
            amount0 += credit0;
            amount1 += credit1;
        }

        if (amount0 > 0) {
            token0.safeTransfer(receiver, amount0);
        }

        if (amount1 > 0) {
            token1.safeTransfer(receiver, amount1);
        }

        emit Burned(receiver, burnAmount, amount0, amount1);
    }

    // Operator Functions => Only called by Vault Operators
    // solhint-disable-next-line code-complexity, function-max-lines
    function rebalance(RebalanceParams calldata rebalanceParams)
        external
        nonReentrant
        onlyOperators
    {
        for (uint256 i = 0; i < rebalanceParams.withdrawTargets.length; i++) {
            require(
                _strategies.contains(rebalanceParams.withdrawTargets[i]),
                "ArrakisVaultV2: untrusted call target"
            );
            (bool success, ) =
                rebalanceParams.withdrawTargets[i].call(
                    rebalanceParams.withdrawPayloads[i]
                );
            require(success, "ArrakisVaultV2: low level call failed");
        }

        for (uint256 j = 0; j < rebalanceParams.approvalTargets.length; j++) {
            require(
                _strategies.contains(rebalanceParams.approvalTargets[j]),
                "ArrakisVaultV2: untrusted call target"
            );
            if (rebalanceParams.approveAmounts0[j] > 0) {
                token0.safeIncreaseAllowance(
                    rebalanceParams.approvalTargets[j],
                    rebalanceParams.approveAmounts0[j]
                );
            }
            if (rebalanceParams.approveAmounts1[j] > 0) {
                token1.safeIncreaseAllowance(
                    rebalanceParams.approvalTargets[j],
                    rebalanceParams.approveAmounts1[j]
                );
            }
        }

        for (uint256 k = 0; k < rebalanceParams.depositTargets.length; k++) {
            require(
                _strategies.contains(rebalanceParams.depositTargets[k]),
                "ArrakisVaultV2: untrusted call target"
            );
            (bool success, ) =
                rebalanceParams.depositTargets[k].call(
                    rebalanceParams.depositPayloads[k]
                );
            require(success, "ArrakisVaultV2: low level call failed");
        }
    }

    /// @notice withdraw manager fees accrued
    function managerWithdrawal() external {
        uint256 amount0;
        uint256 amount1;
        for (uint256 i = 0; i < _strategies.length(); i++) {
            (uint256 a0, uint256 a1) =
                IStrategy(_strategies.at(i)).managerWithdrawal(managerTreasury);
            amount0 += a0;
            amount1 += a1;
        }

        emit ManagerWithdrawal(amount0, amount1);
    }

    // View functions

    /// @notice compute maximum shares that can be minted from `amount0Max` and `amount1Max`
    /// @param amount0Max The maximum amount of token0 to forward on mint
    /// @param amount0Max The maximum amount of token1 to forward on mint
    /// @return amount0 actual amount of token0 to forward when minting `mintAmount`
    /// @return amount1 actual amount of token1 to forward when minting `mintAmount`
    /// @return mintAmount maximum number of shares mintable
    function getMintAmounts(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 mintAmount
        )
    {
        uint256 totalSupply = totalSupply();
        if (totalSupply > 0) {
            (amount0, amount1, mintAmount) = _computeMintAmounts(
                totalSupply,
                amount0Max,
                amount1Max
            );
        // solhint-disable-next-line no-empty-blocks
        } else {
            // TODO: if supply is 0 what do we do ?
        }
    }

    /// @notice compute total underlying holdings of the G-UNI token supply
    /// includes current liquidity invested in uniswap position, current fees earned
    /// and any uninvested leftover (but does not include manager or gelato fees accrued)
    /// @return amount0Current current total underlying balance of token0
    /// @return amount1Current current total underlying balance of token1
    function underlyingBalances()
        public
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        for (uint256 i = 0; i < _strategies.length(); i++) {
            (uint256 amount0, uint256 amount1) =
                IStrategy(_strategies.at(i)).underlyingBalances();
            amount0Current += amount0;
            amount1Current += amount1;
        }
    }

    function underlyingBalancesAtPrice(uint160 sqrtRatioX96)
        public
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        for (uint256 i = 0; i < _strategies.length(); i++) {
            (uint256 amount0, uint256 amount1) =
                IStrategy(_strategies.at(i)).underlyingBalancesAtPrice(
                    sqrtRatioX96
                );
            amount0Current += amount0;
            amount1Current += amount1;
        }
    }

    // solhint-disable-next-line function-max-lines, code-complexity
    function _computeMintAmounts(
        uint256 totalSupply,
        uint256 amount0Max,
        uint256 amount1Max
    )
        private
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 mintAmount
        )
    {
        (uint256 amount0Current, uint256 amount1Current) = underlyingBalances();

        // compute proportional amount of tokens to mint
        if (amount0Current == 0 && amount1Current > 0) {
            mintAmount = FullMath.mulDiv(
                amount1Max,
                totalSupply,
                amount1Current
            );
        } else if (amount1Current == 0 && amount0Current > 0) {
            mintAmount = FullMath.mulDiv(
                amount0Max,
                totalSupply,
                amount0Current
            );
        } else if (amount0Current > 0 && amount1Current > 0) {
            uint256 amount0Mint =
                FullMath.mulDiv(amount0Max, totalSupply, amount0Current);
            uint256 amount1Mint =
                FullMath.mulDiv(amount1Max, totalSupply, amount1Current);
            require(
                amount0Mint > 0 && amount1Mint > 0,
                "ArrakisVaultV2: mint 0"
            );

            mintAmount = amount0Mint < amount1Mint ? amount0Mint : amount1Mint;
        } else {
            revert("ArrakisVaultV2: panic");
        }

        // compute amounts owed to contract
        amount0 = FullMath.mulDivRoundingUp(
            mintAmount,
            amount0Current,
            totalSupply
        );
        amount1 = FullMath.mulDivRoundingUp(
            mintAmount,
            amount1Current,
            totalSupply
        );
    }
}
