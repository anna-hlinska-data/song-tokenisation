// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SongTokenisation} from "../src/SongTokenisation.sol";

contract SongTokenisationTest is Test {
    SongTokenisation internal token;

    address internal owner = makeAddr("owner");
    address internal rightsHolder = makeAddr("rightsHolder");
    address internal fan = makeAddr("fan");
    address internal fan2 = makeAddr("fan2");

    uint256 internal constant SHARES = 1_000;
    uint256 internal constant PRICE = 0.01 ether;

    function setUp() public {
        vm.prank(owner);
        token = new SongTokenisation();

        vm.prank(owner);
        token.createSong("Song A", "Artist A", SHARES, PRICE, rightsHolder);

        vm.deal(owner, 100 ether);
        vm.deal(fan, 100 ether);
        vm.deal(fan2, 100 ether);
    }

    // ---------------------------------------------------------------------
    // Creation and admin
    // ---------------------------------------------------------------------

    function test_CreateSong_AssignsAllSharesToRightsHolder() public view {
        assertEq(token.getTotalAssetsCreated(), 1);
        assertEq(token.getSharesOwned(0, rightsHolder), SHARES);
        SongTokenisation.SongDetails memory d = token.getSongDetails(0);
        assertEq(d.title, "Song A");
        assertEq(d.rightsHolder, rightsHolder);
        assertTrue(d.active);
    }

    function test_CreateSong_RevertsForNonOwner() public {
        vm.prank(fan);
        vm.expectRevert("Only contract owner can do this");
        token.createSong("X", "Y", 10, PRICE, rightsHolder);
    }

    function test_CreateSong_RevertsOnInvalidInput() public {
        vm.startPrank(owner);
        vm.expectRevert("Total shares must be > 0");
        token.createSong("X", "Y", 0, PRICE, rightsHolder);
        vm.expectRevert("Price must be > 0");
        token.createSong("X", "Y", 10, 0, rightsHolder);
        vm.expectRevert("Invalid rights holder");
        token.createSong("X", "Y", 10, PRICE, address(0));
        vm.expectRevert("Invalid rights holder");
        token.createSong("X", "Y", 10, PRICE, address(token));
        vm.stopPrank();
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        token.transferOwnership(fan);
        assertEq(token.owner(), fan);

        vm.prank(owner);
        vm.expectRevert("Only contract owner can do this");
        token.createSong("X", "Y", 10, PRICE, rightsHolder);
    }

    // ---------------------------------------------------------------------
    // Buying and withdrawing
    // ---------------------------------------------------------------------

    function test_Buy_CreditsRightsHolder() public {
        vm.prank(fan);
        token.buySongShares{value: 100 * PRICE}(0, 100);

        assertEq(token.getSharesOwned(0, fan), 100);
        assertEq(token.getSharesOwned(0, rightsHolder), SHARES - 100);
        assertEq(token.pendingWithdrawals(rightsHolder), 1 ether);

        vm.prank(rightsHolder);
        token.withdraw();
        assertEq(rightsHolder.balance, 1 ether);
        assertEq(token.pendingWithdrawals(rightsHolder), 0);
    }

    function test_Buy_RevertsOnWrongValue() public {
        vm.prank(fan);
        vm.expectRevert("Wrong amount of ETH");
        token.buySongShares{value: PRICE}(0, 2);
    }

    function test_Buy_RevertsWhenSoldOut() public {
        vm.prank(fan);
        vm.expectRevert("Not enough shares available");
        token.buySongShares{value: (SHARES + 1) * PRICE}(0, SHARES + 1);
    }

    function test_Buy_RevertsWhenInactive() public {
        vm.prank(owner);
        token.deactivateSong(0);
        vm.prank(fan);
        vm.expectRevert("Song not active");
        token.buySongShares{value: PRICE}(0, 1);
    }

    function test_Buy_RevertsForUnknownSong() public {
        vm.prank(fan);
        vm.expectRevert("Song doesn't exist");
        token.buySongShares{value: PRICE}(7, 1);
    }

    function test_Withdraw_RevertsWhenNothingOwed() public {
        vm.prank(fan);
        vm.expectRevert("Nothing to withdraw");
        token.withdraw();
    }

    /// A smart-contract wallet as rights holder no longer blocks purchases (V1 used `transfer`).
    function test_Buy_WorksWhenRightsHolderIsContract() public {
        ContractWallet wallet = new ContractWallet();
        vm.prank(owner);
        token.createSong("Song B", "Artist B", 100, PRICE, address(wallet));

        vm.prank(fan);
        token.buySongShares{value: PRICE}(1, 1);

        vm.prank(address(wallet));
        token.withdraw();
        assertEq(wallet.received(), PRICE);
    }

    // ---------------------------------------------------------------------
    // Selling back
    // ---------------------------------------------------------------------

    function _fundBuyback(uint256 amount) internal {
        vm.prank(owner);
        token.fundBuyback{value: amount}(0);
    }

    function test_Sell_PaysFromReserveAndMovesSharesToPool() public {
        _fundBuyback(1 ether);
        vm.startPrank(fan);
        token.buySongShares{value: 50 * PRICE}(0, 50);
        uint256 before = fan.balance;
        token.sellSongShares(0, 20);
        vm.stopPrank();

        assertEq(fan.balance - before, 20 * PRICE);
        assertEq(token.getSharesOwned(0, fan), 30);
        assertEq(token.getSharesOwned(0, address(token)), 20);
        assertEq(token.buybackReserve(0), 1 ether - 20 * PRICE);
    }

    function test_Sell_RevertsWithoutReserve() public {
        vm.startPrank(fan);
        token.buySongShares{value: 10 * PRICE}(0, 10);
        vm.expectRevert("Insufficient buyback reserve");
        token.sellSongShares(0, 10);
        vm.stopPrank();
    }

    function test_Sell_ReserveIsPerSong() public {
        vm.prank(owner);
        token.createSong("Song B", "Artist B", 100, PRICE, rightsHolder);
        vm.prank(owner);
        token.fundBuyback{value: 1 ether}(1);

        vm.startPrank(fan);
        token.buySongShares{value: 10 * PRICE}(0, 10);
        vm.expectRevert("Insufficient buyback reserve");
        token.sellSongShares(0, 10);
        vm.stopPrank();
    }

    function test_Buy_TakesFromPoolFirstAndRefillsReserve() public {
        _fundBuyback(1 ether);
        vm.startPrank(fan);
        token.buySongShares{value: 100 * PRICE}(0, 100);
        token.sellSongShares(0, 100);
        vm.stopPrank();
        uint256 owedBefore = token.pendingWithdrawals(rightsHolder);

        vm.prank(fan2);
        token.buySongShares{value: 150 * PRICE}(0, 150);

        assertEq(token.getSharesOwned(0, address(token)), 0, "pool emptied first");
        assertEq(token.buybackReserve(0), 1 ether, "reserve refilled by 100 pool shares");
        assertEq(token.pendingWithdrawals(rightsHolder) - owedBefore, 50 * PRICE, "only 50 new shares paid to RH");
    }

    function test_WithdrawBuybackReserve() public {
        _fundBuyback(2 ether);
        vm.prank(owner);
        token.withdrawBuybackReserve(0, 1.5 ether, payable(owner));
        assertEq(token.buybackReserve(0), 0.5 ether);
        assertEq(owner.balance, 100 ether - 0.5 ether);

        vm.prank(owner);
        vm.expectRevert("Insufficient reserve");
        token.withdrawBuybackReserve(0, 1 ether, payable(owner));
    }

    // ---------------------------------------------------------------------
    // Regression tests for the V1 vulnerabilities (see test/legacy/ExploitV1.t.sol)
    // ---------------------------------------------------------------------

    function test_Security_RightsHolderCannotSellBack() public {
        _fundBuyback(10 ether);
        vm.prank(rightsHolder);
        vm.expectRevert("Rights holder can't sell back");
        token.sellSongShares(0, SHARES);
        assertEq(address(token).balance, 10 ether);
    }

    function test_Security_BuySellLoopDoesNotDrainFunder() public {
        _fundBuyback(1 ether);
        uint256 fanStart = fan.balance;

        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(fan);
            token.buySongShares{value: 100 * PRICE}(0, 100);
            token.sellSongShares(0, 100);
            vm.stopPrank();
        }

        assertEq(fan.balance, fanStart, "fan is whole");
        assertEq(token.pendingWithdrawals(rightsHolder), 1 ether, "rights holder paid once for 100 shares");
        assertEq(token.buybackReserve(0), 0, "first sale used the reserve");
        assertEq(token.getSharesOwned(0, address(token)), 100);
    }

    function test_Security_SellRevertsAfterDeactivation() public {
        _fundBuyback(1 ether);
        vm.prank(fan);
        token.buySongShares{value: 10 * PRICE}(0, 10);
        vm.prank(owner);
        token.deactivateSong(0);

        vm.prank(fan);
        vm.expectRevert("Song not active");
        token.sellSongShares(0, 10);
    }

    function test_Security_SellIsNonReentrant() public {
        _fundBuyback(1 ether);
        ReentrantSeller attacker = new ReentrantSeller(token);
        vm.deal(address(attacker), 1 ether);
        attacker.buy{value: 10 * PRICE}(10, PRICE);

        vm.expectRevert("ETH transfer failed");
        attacker.attack(5);
        assertEq(token.buybackReserve(0), 1 ether);
    }

    function test_Security_CannotTransferIntoPool() public {
        vm.prank(rightsHolder);
        vm.expectRevert("Invalid recipient");
        token.transferSongShares(0, address(token), 10);
    }

    // ---------------------------------------------------------------------
    // Transfers and views
    // ---------------------------------------------------------------------

    function test_Transfer() public {
        vm.prank(rightsHolder);
        token.transferSongShares(0, fan, 10);
        assertEq(token.getSharesOwned(0, fan), 10);

        vm.prank(fan);
        vm.expectRevert("Insufficient shares");
        token.transferSongShares(0, fan2, 11);
    }

    function test_GetAssetOwners_SkipsEmptyHolders() public {
        vm.prank(rightsHolder);
        token.transferSongShares(0, fan, 10);
        vm.prank(fan);
        token.transferSongShares(0, fan2, 10);

        (address[] memory owners, uint256[] memory amounts) = token.getAssetOwners(0);
        assertEq(owners.length, 2);
        assertEq(owners[0], rightsHolder);
        assertEq(amounts[0], SHARES - 10);
        assertEq(owners[1], fan2);
        assertEq(amounts[1], 10);
    }

    function test_GetTop10_SortedWithPercentages() public {
        for (uint256 i = 1; i <= 12; i++) {
            vm.prank(rightsHolder);
            token.transferSongShares(0, address(uint160(0x1000 + i)), i * 10);
        }

        (address[] memory addrs, uint256[] memory shares, uint256[] memory pct) = token.getTop10Beneficiaries(0);

        assertEq(addrs.length, 10);
        assertEq(addrs[0], rightsHolder);
        assertEq(shares[0], SHARES - 780);
        assertEq(pct[0], 2_200); // 22.00%
        assertEq(shares[1], 120);
        assertEq(shares[9], 40);
        for (uint256 i = 1; i < 10; i++) {
            assertGe(shares[i - 1], shares[i]);
        }
    }

    function test_GetAllSongs() public {
        vm.prank(owner);
        token.createSong("Song B", "Artist B", 10, PRICE, rightsHolder);
        (uint256[] memory ids, string[] memory titles,, bool[] memory active) = token.getAllSongs();
        assertEq(ids.length, 2);
        assertEq(titles[1], "Song B");
        assertTrue(active[1]);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_BuySellRoundTripIsNeutralForFan(uint256 amount) public {
        amount = bound(amount, 1, SHARES);
        _fundBuyback(SHARES * PRICE);
        uint256 start = fan.balance;

        vm.startPrank(fan);
        token.buySongShares{value: amount * PRICE}(0, amount);
        token.sellSongShares(0, amount);
        vm.stopPrank();

        assertEq(fan.balance, start);
        assertEq(address(token).balance, token.buybackReserve(0) + token.pendingWithdrawals(rightsHolder));
    }

    function testFuzz_SharesAreConserved(uint256 bought, uint256 sold, uint256 rebought) public {
        bought = bound(bought, 1, SHARES);
        sold = bound(sold, 0, bought);
        rebought = bound(rebought, 0, SHARES - bought + sold);
        _fundBuyback(SHARES * PRICE);

        vm.prank(fan);
        token.buySongShares{value: bought * PRICE}(0, bought);
        if (sold > 0) {
            vm.prank(fan);
            token.sellSongShares(0, sold);
        }
        if (rebought > 0) {
            vm.prank(fan2);
            token.buySongShares{value: rebought * PRICE}(0, rebought);
        }

        uint256 total = token.getSharesOwned(0, rightsHolder) + token.getSharesOwned(0, fan)
            + token.getSharesOwned(0, fan2) + token.getSharesOwned(0, address(token));
        assertEq(total, SHARES);
    }
}

contract ContractWallet {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

contract ReentrantSeller {
    SongTokenisation internal immutable token;
    uint256 internal chunk;

    constructor(SongTokenisation _token) {
        token = _token;
    }

    function buy(uint256 amount, uint256 price) external payable {
        token.buySongShares{value: amount * price}(0, amount);
    }

    function attack(uint256 _chunk) external {
        chunk = _chunk;
        token.sellSongShares(0, _chunk);
    }

    receive() external payable {
        token.sellSongShares(0, chunk);
    }
}
