// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

interface IFlexRouter {
    function routes(address vault, address troveManager) external view returns (address strategy, uint256 minRate);

    function owner_indexes(address troveManager) external view returns (uint256 ownerIndex);

    function set_route(address vault, address troveManager, address strategy, uint256 minRate) external;

    function open_trove(
        address vault,
        address troveManager,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 prevId,
        uint256 nextId,
        uint256 annualInterestRate,
        uint256 maxUpfrontFee
    ) external returns (uint256 troveId);

    function borrow(address vault, address troveManager, uint256 troveId, uint256 debtAmount, uint256 maxUpfrontFee)
        external
        returns (uint256 borrowed);

    function repay(address vault, address troveManager, uint256 troveId, uint256 debtAmount) external;

    function close(address vault, address troveManager, uint256 troveId) external;
}
