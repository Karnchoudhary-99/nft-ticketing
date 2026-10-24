// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/NftTicketing.sol";

contract NftTicketingTest is Test {
    NftTicketing public ticketing;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA901);

    uint256 public constant PRICE = 0.1 ether;
    uint256 public constant CAP = 0.15 ether;

    function setUp() public {
        ticketing = new NftTicketing();
    }

    function _eventId() internal returns (uint256) {
        return ticketing.createEvent(
            "Solana Nights", "Jaipur Arena", block.timestamp + 30 days, PRICE, 2, CAP, "ipfs://tickets/"
        );
    }

    function _buy(address buyer, uint256 eventId) internal returns (uint256) {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        return ticketing.buyTicket{value: PRICE}(eventId);
    }

    // --- Events + primary sale + ERC-721 core ---

    function testCreateEventStoresFields() public {
        uint256 id = _eventId();
        (address organizer,,,,, uint256 maxSupply, uint256 minted,,,,) = ticketing.events(id);
        assertEq(organizer, address(this));
        assertEq(maxSupply, 2);
        assertEq(minted, 0);
        assertTrue(ticketing.checkers(id, address(this)));
    }

    function testCreateEventRejectsPastDateAndZeroSupply() public {
        vm.expectRevert(NftTicketing.EventDateNotInFuture.selector);
        ticketing.createEvent("Past", "X", block.timestamp, PRICE, 10, CAP, "");
        vm.expectRevert(NftTicketing.MaxSupplyZero.selector);
        ticketing.createEvent("NoSupply", "X", block.timestamp + 1 days, PRICE, 0, CAP, "");
    }

    function testBuyTicketMintsWithExactPriceAndTokenURI() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        assertEq(ticketing.ownerOf(tokenId), alice);
        assertEq(ticketing.balanceOf(alice), 1);
        assertEq(ticketing.tokenEvent(tokenId), id);
        assertEq(ticketing.tokenURI(tokenId), "ipfs://tickets/1");
    }

    function testBuyTicketRejectsWrongPaymentAndSoldOut() public {
        uint256 id = _eventId();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NftTicketing.WrongPayment.selector, PRICE, PRICE / 2));
        ticketing.buyTicket{value: PRICE / 2}(id);
        _buy(alice, id);
        _buy(bob, id);
        vm.deal(carol, 10 ether);
        vm.prank(carol);
        vm.expectRevert(NftTicketing.SoldOut.selector);
        ticketing.buyTicket{value: PRICE}(id);
    }

    function testTransferAndApproval() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        vm.prank(alice);
        ticketing.approve(bob, tokenId);
        vm.prank(bob);
        ticketing.transferFrom(alice, bob, tokenId);
        assertEq(ticketing.ownerOf(tokenId), bob);
        assertEq(ticketing.balanceOf(bob), 1);
    }

    function testTransferRejectsStranger() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        vm.prank(carol);
        vm.expectRevert(NftTicketing.NotApprovedOrOwner.selector);
        ticketing.transferFrom(alice, bob, tokenId);
    }

    // --- Transfer controls ---

    function testTransfersDisabledBlocksTransfer() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        ticketing.setTransfersEnabled(id, false);
        vm.prank(alice);
        vm.expectRevert(NftTicketing.TransfersDisabled.selector);
        ticketing.transferFrom(alice, bob, tokenId);
        ticketing.setTransfersEnabled(id, true);
        vm.prank(alice);
        ticketing.transferFrom(alice, bob, tokenId);
        assertEq(ticketing.ownerOf(tokenId), bob);
    }

    function testAllowlistBlocksUnlistedRecipient() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        ticketing.setAllowlistEnabled(id, true);
        vm.prank(alice);
        vm.expectRevert(NftTicketing.RecipientNotAllowlisted.selector);
        ticketing.transferFrom(alice, bob, tokenId);
        ticketing.setAllowlisted(id, bob, true);
        vm.prank(alice);
        ticketing.transferFrom(alice, bob, tokenId);
        assertEq(ticketing.ownerOf(tokenId), bob);
    }

    function testOnlyOrganizerCanToggleControls() public {
        uint256 id = _eventId();
        vm.prank(alice);
        vm.expectRevert(NftTicketing.NotOrganizer.selector);
        ticketing.setTransfersEnabled(id, false);
        vm.prank(alice);
        vm.expectRevert(NftTicketing.NotOrganizer.selector);
        ticketing.setAllowlisted(id, bob, true);
    }

    // --- Resale with price cap ---

    function testResaleAboveCapReverts() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NftTicketing.ResalePriceAboveCap.selector, CAP, CAP + 0.01 ether));
        ticketing.listForResale(tokenId, CAP + 0.01 ether);
    }

    function testResaleMovesTicketAndPaysSeller() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        // Even with direct transfers paused, the capped listing channel works.
        ticketing.setTransfersEnabled(id, false);
        vm.prank(alice);
        ticketing.listForResale(tokenId, CAP);
        uint256 before = alice.balance;
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        ticketing.buyResale{value: CAP}(tokenId);
        assertEq(ticketing.ownerOf(tokenId), bob);
        assertEq(ticketing.resalePrice(tokenId), 0);
        assertEq(alice.balance, before + CAP);
    }

    function testResaleCancelAndUnlistedBuyRevert() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        vm.prank(alice);
        ticketing.listForResale(tokenId, CAP);
        vm.prank(alice);
        ticketing.cancelResale(tokenId);
        assertEq(ticketing.resalePrice(tokenId), 0);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(NftTicketing.NotListed.selector);
        ticketing.buyResale{value: CAP}(tokenId);
    }

    function testResaleDisabledWhenCapIsZero() public {
        uint256 id = ticketing.createEvent(
            "No Resale", "Hall", block.timestamp + 30 days, PRICE, 10, 0, ""
        );
        uint256 tokenId = _buy(alice, id);
        vm.prank(alice);
        vm.expectRevert(NftTicketing.ResaleDisabled.selector);
        ticketing.listForResale(tokenId, PRICE);
    }

    // --- Redemption ---

    function testRedeemOnceByChecker() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        ticketing.setChecker(id, carol, true);
        vm.prank(carol);
        ticketing.redeem(tokenId);
        assertTrue(ticketing.redeemed(tokenId));
        vm.prank(carol);
        vm.expectRevert(NftTicketing.TicketAlreadyRedeemed.selector);
        ticketing.redeem(tokenId);
    }

    function testRedeemRejectsNonChecker() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        vm.prank(bob);
        vm.expectRevert(NftTicketing.NotChecker.selector);
        ticketing.redeem(tokenId);
    }

    function testRedeemedTicketCannotTransferOrList() public {
        uint256 id = _eventId();
        uint256 tokenId = _buy(alice, id);
        ticketing.redeem(tokenId); // organizer is a checker by default
        vm.prank(alice);
        vm.expectRevert(NftTicketing.TicketRedeemed.selector);
        ticketing.transferFrom(alice, bob, tokenId);
        vm.prank(alice);
        vm.expectRevert(NftTicketing.TicketRedeemed.selector);
        ticketing.listForResale(tokenId, CAP);
    }
}
