# @version 0.4.3

"""
@title Flex Router
@license GNU AGPLv3
@notice Routes Yearn V3 vault debt into Flex lender markets.
"""

from ethereum.ercs import IERC20


event RouteUpdated:
    vault: indexed(address)
    trove_manager: indexed(address)
    strategy: indexed(address)
    min_rate: uint256
    sender: address


event BorrowOpened:
    vault: indexed(address)
    strategy: indexed(address)
    borrower: indexed(address)
    trove_id: uint256
    debt_amount: uint256
    annual_interest_rate: uint256


event Borrowed:
    vault: indexed(address)
    trove_manager: address
    strategy: indexed(address)
    borrower: indexed(address)
    trove_id: uint256
    debt_amount: uint256


event Repaid:
    vault: indexed(address)
    strategy: indexed(address)
    borrower: indexed(address)
    trove_id: uint256
    debt_amount: uint256


event Closed:
    vault: indexed(address)
    strategy: indexed(address)
    borrower: indexed(address)
    trove_id: uint256


struct Trove:
    debt: uint256
    collateral: uint256
    annual_interest_rate: uint256
    last_debt_update_time: uint64
    last_interest_rate_adj_time: uint64
    owner: address
    status: uint8


struct StrategyParams:
    activation: uint256
    last_report: uint256
    current_debt: uint256
    max_debt: uint256


struct Route:
    strategy: address
    min_rate: uint256


interface IVault:
    def asset() -> address: view
    def roles(account: address) -> uint256: view
    def totalIdle() -> uint256: view
    def default_queue(index: uint256) -> address: view
    def strategies(strategy: address) -> StrategyParams: view
    def update_debt(strategy: address, target_debt: uint256, max_loss: uint256 = 10000) -> uint256: nonpayable


interface ITroveManager:
    def lender() -> address: view
    def borrow_token() -> address: view
    def collateral_token() -> address: view
    def min_debt() -> uint256: view
    def get_trove_debt_after_interest(trove_id: uint256) -> uint256: view
    def troves(trove_id: uint256) -> Trove: view
    def approved(owner: address, operator: address) -> bool: view
    def open_trove(
        owner_index: uint256,
        collateral_amount: uint256,
        debt_amount: uint256,
        prev_id: uint256,
        next_id: uint256,
        annual_interest_rate: uint256,
        max_upfront_fee: uint256,
        min_borrow_out: uint256,
        min_collateral_out: uint256,
        owner: address,
    ) -> uint256: nonpayable
    def borrow(
        trove_id: uint256,
        debt_amount: uint256,
        max_upfront_fee: uint256,
        min_borrow_out: uint256,
        min_collateral_out: uint256,
    ): nonpayable
    def repay(trove_id: uint256, debt_amount: uint256): nonpayable
    def close_trove(trove_id: uint256): nonpayable


DEBT_MANAGER_ROLE: constant(uint256) = 64


routes: public(HashMap[address, HashMap[address, Route]])
owner_indexes: public(HashMap[address, uint256])


@external
def set_route(vault: address, trove_manager: address, strategy: address, min_rate: uint256):
    self._check_manager(vault)
    assert trove_manager != empty(address), "!trove_manager"
    assert staticcall IVault(vault).asset() == staticcall ITroveManager(trove_manager).borrow_token(), "!market_asset"
    assert staticcall ITroveManager(trove_manager).lender() != empty(address), "!lender"
    assert strategy != empty(address), "!strategy"
    params: StrategyParams = staticcall IVault(vault).strategies(strategy)
    assert params.activation != 0, "!strategy"
    assert min_rate != 0, "!min_rate"

    self.routes[vault][trove_manager] = Route(strategy=strategy, min_rate=min_rate)

    log RouteUpdated(
        vault=vault,
        trove_manager=trove_manager,
        strategy=strategy,
        min_rate=min_rate,
        sender=msg.sender,
    )


@external
def open_trove(
    vault: address,
    trove_manager: address,
    collateral_amount: uint256,
    debt_amount: uint256,
    prev_id: uint256,
    next_id: uint256,
    annual_interest_rate: uint256,
    max_upfront_fee: uint256,
) -> uint256:
    route: Route = self.routes[vault][trove_manager]
    assert route.strategy != empty(address), "!route_disabled"
    assert route.min_rate != 0, "!route_disabled"
    assert annual_interest_rate >= route.min_rate, "!min_rate"

    owner_index: uint256 = self.owner_indexes[trove_manager]
    self.owner_indexes[trove_manager] = owner_index + 1

    collateral_token: address = staticcall ITroveManager(trove_manager).collateral_token()
    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()

    self._pull(collateral_token, collateral_amount)
    self._approve(collateral_token, trove_manager, collateral_amount)
    self._fund(vault, trove_manager, route.strategy, debt_amount)

    balance_before: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    trove_id: uint256 = extcall ITroveManager(trove_manager).open_trove(
        owner_index,
        collateral_amount,
        debt_amount,
        prev_id,
        next_id,
        annual_interest_rate,
        max_upfront_fee,
        debt_amount,
        0,
        msg.sender,
    )
    self._send(borrow_token, msg.sender, staticcall IERC20(borrow_token).balanceOf(self) - balance_before)
    self._approve(collateral_token, trove_manager, 0)

    log BorrowOpened(
        vault=vault,
        strategy=route.strategy,
        borrower=msg.sender,
        trove_id=trove_id,
        debt_amount=debt_amount,
        annual_interest_rate=annual_interest_rate,
    )

    return trove_id


@external
def borrow(
    vault: address,
    trove_manager: address,
    trove_id: uint256,
    debt_amount: uint256,
    max_upfront_fee: uint256,
) -> uint256:
    route: Route = self.routes[vault][trove_manager]
    assert route.strategy != empty(address), "!route_disabled"
    assert route.min_rate != 0, "!route_disabled"
    trove: Trove = self._trove_for_sender(trove_manager, trove_id)
    assert trove.annual_interest_rate >= route.min_rate, "!min_rate"
    self._fund(vault, trove_manager, route.strategy, debt_amount)

    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()
    balance_before: uint256 = staticcall IERC20(borrow_token).balanceOf(self)
    extcall ITroveManager(trove_manager).borrow(
        trove_id,
        debt_amount,
        max_upfront_fee,
        debt_amount,
        0,
    )

    borrowed: uint256 = staticcall IERC20(borrow_token).balanceOf(self) - balance_before
    self._send(borrow_token, msg.sender, borrowed)

    log Borrowed(
        vault=vault,
        trove_manager=trove_manager,
        strategy=route.strategy,
        borrower=msg.sender,
        trove_id=trove_id,
        debt_amount=debt_amount,
    )

    return borrowed


@external
def repay(
    vault: address,
    trove_manager: address,
    trove_id: uint256,
    debt_amount: uint256,
):
    route: Route = self.routes[vault][trove_manager]
    assert route.strategy != empty(address), "!route_disabled"
    self._trove_for_sender(trove_manager, trove_id)

    debt_after_interest: uint256 = staticcall ITroveManager(trove_manager).get_trove_debt_after_interest(trove_id)
    min_debt: uint256 = staticcall ITroveManager(trove_manager).min_debt()
    assert debt_after_interest > min_debt, "!max_repayment"

    actual_repayment: uint256 = min(debt_amount, debt_after_interest - min_debt)
    assert actual_repayment != 0, "!repayment"

    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()
    self._pull(borrow_token, actual_repayment)
    self._approve(borrow_token, trove_manager, actual_repayment)
    extcall ITroveManager(trove_manager).repay(trove_id, actual_repayment)
    self._approve(borrow_token, trove_manager, 0)

    self._drain(vault, route.strategy)

    log Repaid(
        vault=vault,
        strategy=route.strategy,
        borrower=msg.sender,
        trove_id=trove_id,
        debt_amount=actual_repayment,
    )


@external
def close(vault: address, trove_manager: address, trove_id: uint256):
    route: Route = self.routes[vault][trove_manager]
    assert route.strategy != empty(address), "!route_disabled"
    self._trove_for_sender(trove_manager, trove_id)

    debt_after_interest: uint256 = staticcall ITroveManager(trove_manager).get_trove_debt_after_interest(trove_id)
    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()
    collateral_token: address = staticcall ITroveManager(trove_manager).collateral_token()

    self._pull(borrow_token, debt_after_interest)
    self._approve(borrow_token, trove_manager, debt_after_interest)

    collateral_before: uint256 = staticcall IERC20(collateral_token).balanceOf(self)
    extcall ITroveManager(trove_manager).close_trove(trove_id)
    self._approve(borrow_token, trove_manager, 0)
    self._send(collateral_token, msg.sender, staticcall IERC20(collateral_token).balanceOf(self) - collateral_before)

    self._drain(vault, route.strategy)

    log Closed(
        vault=vault,
        strategy=route.strategy,
        borrower=msg.sender,
        trove_id=trove_id,
    )


@internal
def _pull(token: address, amount: uint256):
    if amount != 0:
        assert extcall IERC20(token).transferFrom(msg.sender, self, amount, default_return_value=True), "transferFrom failed"


@internal
def _approve(token: address, spender: address, amount: uint256):
    assert extcall IERC20(token).approve(spender, 0, default_return_value=True), "approve reset failed"
    assert extcall IERC20(token).approve(spender, amount, default_return_value=True), "approve failed"


@internal
def _send(token: address, receiver: address, amount: uint256):
    if amount != 0:
        assert extcall IERC20(token).transfer(receiver, amount, default_return_value=True), "transfer failed"


@internal
def _check_manager(vault: address):
    assert (staticcall IVault(vault).roles(msg.sender) & DEBT_MANAGER_ROLE) != 0, "!vault_manager"


@internal
def _trove_for_sender(trove_manager: address, trove_id: uint256) -> Trove:
    trove: Trove = staticcall ITroveManager(trove_manager).troves(trove_id)
    assert trove.owner == msg.sender, "!trove_owner"
    assert staticcall ITroveManager(trove_manager).approved(msg.sender, self), "!router_approved"
    return trove


@internal
def _fund(vault: address, trove_manager: address, strategy: address, amount: uint256):
    if amount == 0:
        return

    lender: address = staticcall ITroveManager(trove_manager).lender()
    borrow_token: address = staticcall ITroveManager(trove_manager).borrow_token()
    lender_idle: uint256 = staticcall IERC20(borrow_token).balanceOf(lender)
    if lender_idle >= amount:
        return

    amount_to_fund: uint256 = amount - lender_idle
    strategy_params: StrategyParams = staticcall IVault(vault).strategies(strategy)

    total_idle: uint256 = staticcall IVault(vault).totalIdle()
    if total_idle < amount_to_fund:
        deficit: uint256 = amount_to_fund - total_idle
        base_strategy: address = staticcall IVault(vault).default_queue(0)
        assert base_strategy != empty(address), "!base_strategy"
        assert base_strategy != strategy, "!base_strategy"

        base_params: StrategyParams = staticcall IVault(vault).strategies(base_strategy)
        base_target: uint256 = 0
        if base_params.current_debt > deficit:
            base_target = base_params.current_debt - deficit

        extcall IVault(vault).update_debt(base_strategy, base_target)

    extcall IVault(vault).update_debt(strategy, strategy_params.current_debt + amount_to_fund)


@internal
def _refill_base(vault: address, strategy: address):
    base_strategy: address = staticcall IVault(vault).default_queue(0)
    if base_strategy != empty(address) and base_strategy != strategy:
        extcall IVault(vault).update_debt(base_strategy, max_value(uint256))


@internal
def _drain(vault: address, strategy: address):
    params: StrategyParams = staticcall IVault(vault).strategies(strategy)
    if params.current_debt != 0:
        extcall IVault(vault).update_debt(strategy, 0, 1)
    
    self._refill_base(vault, strategy)
