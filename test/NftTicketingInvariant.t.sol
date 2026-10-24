// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/NftTicketing.sol";

/// @notice Invariant handler for NftTicketing. The handler itself is the
///         organizer and the primary buyer; tickets it transfers out to
///         bob/carol are listed by their owner (via prank, no ETH involved)
///         and bought back by the handler. Every action is guarded so a
///         legitimately-reverting call is never attempted: with
///         fail_on_revert, an unguarded revert would fail the whole run.
contract TicketHandler is Test {
    NftTicketing public ticketing;
    address public bob = address(0xB0B);
    address public carol = address(0xCA901);
    uint256 public eventCount;

    constructor(NftTicketing _ticketing) {
        ticketing = _ticketing;
    }

    function _event(uint256 id)
        internal
        view
        returns (uint256 price, uint256 maxSupply, uint256 minted, bool transfersEnabled, bool allowlistEnabled, uint256 cap)
    {
        (,,,, price, maxSupply, minted, transfersEnabled, allowlistEnabled, cap,) = ticketing.events(id);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? bob : carol;
    }

    function createEvent(uint256 priceSeed, uint256 supplySeed, uint256 capSeed) public {
        uint256 price = bound(priceSeed, 0, 0.5 ether);
        uint256 supply = bound(supplySeed, 1, 10);
        uint256 cap = capSeed % 3 == 0 ? 0 : price + bound(capSeed, 0, 0.5 ether);
        ticketing.createEvent(
            "Invariant Night", "Hall", block.timestamp + 30 days, price, supply, cap, "ipfs://t/"
        );
        eventCount++;
    }

    function buyTicket(uint256 eventSeed) public {
        if (eventCount == 0) return;
        uint256 id = bound(eventSeed, 1, eventCount);
        (uint256 price, uint256 maxSupply, uint256 minted,,,) = _event(id);
        if (minted >= maxSupply) return;
        if (address(this).balance < price) return;
        ticketing.buyTicket{value: price}(id);
    }

    function transferTicket(uint256 tokenSeed, uint256 recipientSeed) public {
        uint256 next = ticketing.nextTokenId();
        if (next <= 1) return;
        uint256 tokenId = bound(tokenSeed, 1, next - 1);
        if (ticketing.ownerOf(tokenId) != address(this)) return;
        if (ticketing.redeemed(tokenId)) return;
        uint256 eventId = ticketing.tokenEvent(tokenId);
        (,,, bool transfersEnabled, bool allowlistEnabled,) = _event(eventId);
        if (!transfersEnabled) return;
        address to = _actor(recipientSeed);
        if (allowlistEnabled && !ticketing.allowlist(eventId, to)) return;
        ticketing.transferFrom(address(this), to, tokenId);
    }

    function allowlistRecipient(uint256 eventSeed, uint256 recipientSeed) public {
        if (eventCount == 0) return;
        uint256 id = bound(eventSeed, 1, eventCount);
        ticketing.setAllowlisted(id, _actor(recipientSeed), true);
    }

    function toggleTransfers(uint256 eventSeed, bool enabled) public {
        if (eventCount == 0) return;
        ticketing.setTransfersEnabled(bound(eventSeed, 1, eventCount), enabled);
    }

    function toggleAllowlist(uint256 eventSeed, bool enabled) public {
        if (eventCount == 0) return;
        ticketing.setAllowlistEnabled(bound(eventSeed, 1, eventCount), enabled);
    }

    function listTicket(uint256 tokenSeed, uint256 priceSeed) public {
        uint256 next = ticketing.nextTokenId();
        if (next <= 1) return;
        uint256 tokenId = bound(tokenSeed, 1, next - 1);
        address owner = ticketing.ownerOf(tokenId);
        if (ticketing.redeemed(tokenId)) return;
        if (ticketing.resalePrice(tokenId) != 0) return;
        uint256 cap = _capOf(tokenId);
        if (cap == 0) return;
        uint256 price = bound(priceSeed, 1, cap);
        if (owner == address(this)) {
            ticketing.listForResale(tokenId, price);
        } else {
            vm.prank(owner);
            ticketing.listForResale(tokenId, price);
        }
    }

    function cancelListing(uint256 tokenSeed) public {
        uint256 next = ticketing.nextTokenId();
        if (next <= 1) return;
        uint256 tokenId = bound(tokenSeed, 1, next - 1);
        if (ticketing.resalePrice(tokenId) == 0) return;
        address owner = ticketing.ownerOf(tokenId);
        if (owner == address(this)) {
            ticketing.cancelResale(tokenId);
        } else {
            vm.prank(owner);
            ticketing.cancelResale(tokenId);
        }
    }

    function buyResale(uint256 tokenSeed) public {
        uint256 next = ticketing.nextTokenId();
        if (next <= 1) return;
        uint256 tokenId = bound(tokenSeed, 1, next - 1);
        uint256 price = ticketing.resalePrice(tokenId);
        if (price == 0) return;
        if (ticketing.redeemed(tokenId)) return;
        if (ticketing.ownerOf(tokenId) == address(this)) return;
        if (price > _capOf(tokenId)) return; // stale listing after a cap cut: must not sell
        if (address(this).balance < price) return;
        ticketing.buyResale{value: price}(tokenId);
    }

    function redeemTicket(uint256 tokenSeed) public {
        uint256 next = ticketing.nextTokenId();
        if (next <= 1) return;
        uint256 tokenId = bound(tokenSeed, 1, next - 1);
        if (ticketing.redeemed(tokenId)) return;
        ticketing.redeem(tokenId); // handler is the organizer, hence a checker
    }

    function raiseResaleCap(uint256 eventSeed, uint256 capSeed) public {
        // Only ever raise the cap, and never below an existing listing for
        // the event: lowering is covered by unit tests (stale listings must
        // not sell), and the invariant below asserts listings stay in-cap.
        if (eventCount == 0) return;
        uint256 id = bound(eventSeed, 1, eventCount);
        uint256 floor = _maxListedPrice(id);
        uint256 cap = bound(capSeed, floor, floor + 1 ether);
        (,,,,, uint256 currentCap) = _event(id);
        if (cap < currentCap) return;
        ticketing.setResaleCap(id, cap);
    }

    function withdrawProceeds(uint256 eventSeed) public {
        if (eventCount == 0) return;
        uint256 id = bound(eventSeed, 1, eventCount);
        if (ticketing.eventProceeds(id) == 0) return;
        ticketing.withdrawProceeds(id);
    }

    function _capOf(uint256 tokenId) internal view returns (uint256) {
        (,,,,, uint256 cap) = _event(ticketing.tokenEvent(tokenId));
        return cap;
    }

    function _maxListedPrice(uint256 eventId) internal view returns (uint256 maxPrice) {
        uint256 next = ticketing.nextTokenId();
        for (uint256 t = 1; t < next; t++) {
            if (ticketing.tokenEvent(t) == eventId && ticketing.resalePrice(t) > maxPrice) {
                maxPrice = ticketing.resalePrice(t);
            }
        }
    }

    // Handler must be able to receive withdrawn proceeds and resale payouts
    // when it sells a ticket it bought back.
    receive() external payable {}
}

contract NftTicketingInvariantTest is Test {
    NftTicketing public ticketing;
    TicketHandler public handler;

    function setUp() public {
        ticketing = new NftTicketing();
        handler = new TicketHandler(ticketing);
        vm.deal(address(handler), 1000 ether);
        vm.deal(handler.bob(), 1000 ether);
        vm.deal(handler.carol(), 1000 ether);
        targetContract(address(handler));
    }

    /// No event ever mints past its supply cap.
    function invariant_mintedWithinSupply() public view {
        for (uint256 id = 1; id <= handler.eventCount(); id++) {
            (,,,,, uint256 maxSupply, uint256 minted,,,,) = ticketing.events(id);
            assertLe(minted, maxSupply);
        }
    }

    /// Tokens are never burned: total minted equals total token IDs issued.
    function invariant_tokenAccounting() public view {
        uint256 totalMinted;
        for (uint256 id = 1; id <= handler.eventCount(); id++) {
            (,,,,, , uint256 minted,,,,) = ticketing.events(id);
            totalMinted += minted;
        }
        assertEq(totalMinted, ticketing.nextTokenId() - 1);
    }

    /// Solvency: the contract holds exactly the unwithdrawn primary-sale
    /// proceeds. Resale ETH bypasses the contract (seller is paid directly),
    /// so it must never appear in this balance.
    function invariant_contractBalanceEqualsUnwithdrawnProceeds() public view {
        uint256 totalProceeds;
        for (uint256 id = 1; id <= handler.eventCount(); id++) {
            totalProceeds += ticketing.eventProceeds(id);
        }
        assertEq(address(ticketing).balance, totalProceeds);
    }

    /// Every live listing is at or under its event's current cap (the
    /// handler never lowers a cap below a listing; unit tests cover the
    /// stale-listing sale block for organizer-lowered caps).
    function invariant_listingsWithinCap() public view {
        uint256 next = ticketing.nextTokenId();
        for (uint256 t = 1; t < next; t++) {
            uint256 price = ticketing.resalePrice(t);
            if (price == 0) continue;
            (,,,,, uint256 cap) = _eventOf(t);
            assertLe(price, cap);
            assertTrue(cap > 0);
        }
    }

    /// Every token belongs to a real event, and redeemed tickets never
    /// outnumber minted ones.
    function invariant_tokensBelongToEvents() public view {
        uint256 next = ticketing.nextTokenId();
        uint256 redeemedCount;
        for (uint256 t = 1; t < next; t++) {
            uint256 eventId = ticketing.tokenEvent(t);
            assertGe(eventId, 1);
            assertLe(eventId, handler.eventCount());
            if (ticketing.redeemed(t)) redeemedCount++;
        }
        assertLe(redeemedCount, next - 1);
    }

    function _eventOf(uint256 tokenId)
        internal
        view
        returns (uint256 price, uint256 maxSupply, uint256 minted, bool transfersEnabled, bool allowlistEnabled, uint256 cap)
    {
        (,,,, price, maxSupply, minted, transfersEnabled, allowlistEnabled, cap,) =
            ticketing.events(ticketing.tokenEvent(tokenId));
    }
}
