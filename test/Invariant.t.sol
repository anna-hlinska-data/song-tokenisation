// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SongTokenisation} from "../src/SongTokenisation.sol";

/// Drives random sequences of buys, sells, transfers, funding and withdrawals.
contract Handler is Test {
    SongTokenisation internal token;
    address internal owner;
    address internal rightsHolder;
    address[] internal fans;

    uint256 internal constant PRICE = 0.01 ether;

    constructor(SongTokenisation _token, address _owner, address _rightsHolder) {
        token = _token;
        owner = _owner;
        rightsHolder = _rightsHolder;
        for (uint256 i = 0; i < 4; i++) {
            address fan = makeAddr(string(abi.encodePacked("fan", vm.toString(i))));
            fans.push(fan);
            vm.deal(fan, 1_000 ether);
        }
        vm.deal(owner, 1_000 ether);
    }

    function _fan(uint256 seed) internal view returns (address) {
        return fans[seed % fans.length];
    }

    function buy(uint256 seed, uint256 amount) external {
        uint256 available = token.getSharesOwned(0, rightsHolder) + token.getSharesOwned(0, address(token));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(_fan(seed));
        token.buySongShares{value: amount * PRICE}(0, amount);
    }

    function sell(uint256 seed, uint256 amount) external {
        address fan = _fan(seed);
        uint256 maxByShares = token.getSharesOwned(0, fan);
        uint256 maxByReserve = token.buybackReserve(0) / PRICE;
        uint256 max = maxByShares < maxByReserve ? maxByShares : maxByReserve;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(fan);
        token.sellSongShares(0, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _fan(fromSeed);
        uint256 balance = token.getSharesOwned(0, from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        token.transferSongShares(0, _fan(toSeed), amount);
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        vm.prank(owner);
        token.fundBuyback{value: amount}(0);
    }

    function withdrawReserve(uint256 amount) external {
        uint256 reserve = token.buybackReserve(0);
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        vm.prank(owner);
        token.withdrawBuybackReserve(0, amount, payable(owner));
    }

    function withdrawEarnings() external {
        if (token.pendingWithdrawals(rightsHolder) == 0) return;
        vm.prank(rightsHolder);
        token.withdraw();
    }

    function sumShares() external view returns (uint256 total) {
        total = token.getSharesOwned(0, rightsHolder) + token.getSharesOwned(0, address(token));
        for (uint256 i = 0; i < fans.length; i++) {
            total += token.getSharesOwned(0, fans[i]);
        }
    }
}

contract InvariantTest is Test {
    SongTokenisation internal token;
    Handler internal handler;
    address internal owner = makeAddr("owner");
    address internal rightsHolder = makeAddr("rightsHolder");

    uint256 internal constant SHARES = 1_000;

    function setUp() public {
        vm.prank(owner);
        token = new SongTokenisation();
        vm.prank(owner);
        token.createSong("Song A", "Artist A", SHARES, 0.01 ether, rightsHolder);

        handler = new Handler(token, owner, rightsHolder);
        targetContract(address(handler));
    }

    /// Every wei held by the contract is either buy-back reserve or owed to the rights holder.
    function invariant_BalanceMatchesAccounting() public view {
        assertEq(address(token).balance, token.buybackReserve(0) + token.pendingWithdrawals(rightsHolder));
    }

    function invariant_SharesAreConserved() public view {
        assertEq(handler.sumShares(), SHARES);
    }
}
