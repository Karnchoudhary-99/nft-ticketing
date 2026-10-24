// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title NftTicketing
/// @notice Event tickets as NFTs: one contract hosts many events. An
///         organizer creates an event with a price and a supply cap, buyers
///         mint tickets by paying exactly that price, and tickets are
///         redeemed exactly once at the door by an organizer-appointed
///         checker. Transfer controls fight scalping and counterfeits:
///         organizers can pause direct transfers, restrict transfers to an
///         allowlist, and cap resale prices. Resale goes through an on-chain
///         listing so the price cap is enforced by the contract, not by
///         marketplace goodwill. No external dependencies — a minimal ERC-721
///         core is implemented here so the repo builds with vanilla Foundry.
contract NftTicketing {
    // ------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------

    struct Event {
        address organizer;
        string name;
        string venue;
        uint256 date;
        uint256 price;
        uint256 maxSupply;
        uint256 minted;
        bool transfersEnabled;
        bool allowlistEnabled;
        uint256 resaleCap; // 0 = resale disabled for this event
        string baseURI;
    }

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error NotOrganizer();
    error NotChecker();
    error NotTokenOwner();
    error NotApprovedOrOwner();
    error EventNotFound();
    error TokenNotFound();
    error EventDateNotInFuture();
    error MaxSupplyZero();
    error WrongPayment(uint256 expected, uint256 received);
    error SoldOut();
    error EventAlreadyStarted();
    error TransfersDisabled();
    error RecipientNotAllowlisted();
    error TicketRedeemed();
    error TicketAlreadyRedeemed();
    error ResaleDisabled();
    error ResalePriceAboveCap(uint256 cap, uint256 price);
    error NotListed();
    error ResalePriceZero();
    error ZeroAddress();
    error TransferFailed(address to, uint256 amount);
    error CannotBuyOwnTicket();
    error ReentrantCall();
    error NoProceeds();

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event EventCreated(
        uint256 indexed eventId,
        address indexed organizer,
        string name,
        uint256 price,
        uint256 maxSupply
    );
    event TicketMinted(uint256 indexed tokenId, uint256 indexed eventId, address indexed buyer);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event TransfersToggled(uint256 indexed eventId, bool enabled);
    event AllowlistToggled(uint256 indexed eventId, bool enabled);
    event Allowlisted(uint256 indexed eventId, address indexed account, bool allowed);
    event CheckerSet(uint256 indexed eventId, address indexed checker, bool allowed);
    event ResaleCapSet(uint256 indexed eventId, uint256 cap);
    event ListedForResale(uint256 indexed tokenId, address indexed seller, uint256 price);
    event ResaleCancelled(uint256 indexed tokenId, address indexed seller);
    event Resold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event Redeemed(uint256 indexed tokenId, uint256 indexed eventId, address indexed checker);
    event ProceedsWithdrawn(uint256 indexed eventId, address indexed organizer, uint256 amount);

    // ------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------

    string public constant name = "NFTTicketing";
    string public constant symbol = "TIX";

    uint256 public nextEventId = 1;
    uint256 public nextTokenId = 1;

    mapping(uint256 => Event) public events;
    mapping(uint256 => uint256) public tokenEvent; // tokenId -> eventId
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => bool) public redeemed;
    mapping(uint256 => uint256) public resalePrice; // 0 = not listed
    mapping(uint256 => mapping(address => bool)) public allowlist;
    mapping(uint256 => mapping(address => bool)) public checkers;
    mapping(uint256 => uint256) public eventProceeds; // primary-sale ETH per event, awaiting organizer withdrawal

    uint256 private _locked;

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_locked == 1) revert ReentrantCall();
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier onlyOrganizer(uint256 eventId) {
        if (events[eventId].organizer == address(0)) revert EventNotFound();
        if (msg.sender != events[eventId].organizer) revert NotOrganizer();
        _;
    }

    // ------------------------------------------------------------------------
    // ERC-721 core (minimal)
    // ------------------------------------------------------------------------

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert TokenNotFound();
        return owner;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert TokenNotFound();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert NotApprovedOrOwner();
        }
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        if (operator == address(0)) revert ZeroAddress();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        if (from != owner) revert NotApprovedOrOwner();
        if (to == address(0)) revert ZeroAddress();
        if (
            msg.sender != owner && _tokenApprovals[tokenId] != msg.sender
                && !_operatorApprovals[owner][msg.sender]
        ) revert NotApprovedOrOwner();
        _transfer(from, to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        if (redeemed[tokenId]) revert TicketRedeemed();
        uint256 eventId = tokenEvent[tokenId];
        Event storage ev = events[eventId];
        if (!ev.transfersEnabled) revert TransfersDisabled();
        if (ev.allowlistEnabled && !allowlist[eventId][to]) revert RecipientNotAllowlisted();
        _tokenApprovals[tokenId] = address(0);
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function _mint(address to, uint256 eventId) internal returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        tokenEvent[tokenId] = eventId;
        _owners[tokenId] = to;
        _balances[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TokenNotFound();
        return string.concat(events[tokenEvent[tokenId]].baseURI, _toString(tokenId));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 v = value;
        while (v != 0) {
            digits++;
            v /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buf);
    }

    // ------------------------------------------------------------------------
    // Events + primary sale
    // ------------------------------------------------------------------------

    function createEvent(
        string calldata eventName,
        string calldata venue,
        uint256 date,
        uint256 price,
        uint256 maxSupply,
        uint256 resaleCap,
        string calldata baseURI
    ) external returns (uint256 eventId) {
        if (date <= block.timestamp) revert EventDateNotInFuture();
        if (maxSupply == 0) revert MaxSupplyZero();
        eventId = nextEventId++;
        events[eventId] = Event({
            organizer: msg.sender,
            name: eventName,
            venue: venue,
            date: date,
            price: price,
            maxSupply: maxSupply,
            minted: 0,
            transfersEnabled: true,
            allowlistEnabled: false,
            resaleCap: resaleCap,
            baseURI: baseURI
        });
        checkers[eventId][msg.sender] = true;
        emit EventCreated(eventId, msg.sender, eventName, price, maxSupply);
    }

    function buyTicket(uint256 eventId) external payable returns (uint256 tokenId) {
        Event storage ev = events[eventId];
        if (ev.organizer == address(0)) revert EventNotFound();
        if (block.timestamp > ev.date) revert EventAlreadyStarted();
        if (ev.minted >= ev.maxSupply) revert SoldOut();
        if (msg.value != ev.price) revert WrongPayment(ev.price, msg.value);
        ev.minted += 1;
        eventProceeds[eventId] += msg.value;
        tokenId = _mint(msg.sender, eventId);
        emit TicketMinted(tokenId, eventId, msg.sender);
    }

    // ------------------------------------------------------------------------
    // Organizer controls
    // ------------------------------------------------------------------------

    function setTransfersEnabled(uint256 eventId, bool enabled) external onlyOrganizer(eventId) {
        events[eventId].transfersEnabled = enabled;
        emit TransfersToggled(eventId, enabled);
    }

    function setAllowlistEnabled(uint256 eventId, bool enabled) external onlyOrganizer(eventId) {
        events[eventId].allowlistEnabled = enabled;
        emit AllowlistToggled(eventId, enabled);
    }

    function setAllowlisted(uint256 eventId, address account, bool allowed)
        external
        onlyOrganizer(eventId)
    {
        if (account == address(0)) revert ZeroAddress();
        allowlist[eventId][account] = allowed;
        emit Allowlisted(eventId, account, allowed);
    }

    function setChecker(uint256 eventId, address checker, bool allowed)
        external
        onlyOrganizer(eventId)
    {
        if (checker == address(0)) revert ZeroAddress();
        checkers[eventId][checker] = allowed;
        emit CheckerSet(eventId, checker, allowed);
    }

    function setResaleCap(uint256 eventId, uint256 cap) external onlyOrganizer(eventId) {
        events[eventId].resaleCap = cap;
        emit ResaleCapSet(eventId, cap);
    }

    /// @notice Withdraw accumulated primary-sale proceeds for an event.
    /// @dev Resale payments go straight to the seller, so the contract only
    ///      ever holds primary-sale ETH; that is exactly what this pays out.
    ///      Without this, ticket revenue would be locked in the contract.
    function withdrawProceeds(uint256 eventId) external onlyOrganizer(eventId) nonReentrant {
        uint256 amount = eventProceeds[eventId];
        if (amount == 0) revert NoProceeds();
        eventProceeds[eventId] = 0;
        (bool ok,) = events[eventId].organizer.call{value: amount}("");
        if (!ok) revert TransferFailed(events[eventId].organizer, amount);
        emit ProceedsWithdrawn(eventId, events[eventId].organizer, amount);
    }

    // ------------------------------------------------------------------------
    // Resale (price cap enforced on-chain)
    // ------------------------------------------------------------------------

    function listForResale(uint256 tokenId, uint256 price) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner) revert NotTokenOwner();
        if (redeemed[tokenId]) revert TicketRedeemed();
        if (price == 0) revert ResalePriceZero();
        uint256 cap = events[tokenEvent[tokenId]].resaleCap;
        if (cap == 0) revert ResaleDisabled();
        if (price > cap) revert ResalePriceAboveCap(cap, price);
        resalePrice[tokenId] = price;
        emit ListedForResale(tokenId, owner, price);
    }

    function cancelResale(uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner) revert NotTokenOwner();
        if (resalePrice[tokenId] == 0) revert NotListed();
        resalePrice[tokenId] = 0;
        emit ResaleCancelled(tokenId, owner);
    }

    function buyResale(uint256 tokenId) external payable nonReentrant {
        uint256 price = resalePrice[tokenId];
        if (price == 0) revert NotListed();
        // Re-check the cap at purchase time: the organizer may have lowered
        // it after this listing was created, and a stale listing must not be
        // able to sell above the current cap (cap 0 = resale now disabled).
        uint256 cap = events[tokenEvent[tokenId]].resaleCap;
        if (price > cap) revert ResalePriceAboveCap(cap, price);
        if (redeemed[tokenId]) revert TicketRedeemed();
        if (msg.value != price) revert WrongPayment(price, msg.value);
        address seller = ownerOf(tokenId);
        if (msg.sender == seller) revert CannotBuyOwnTicket();
        resalePrice[tokenId] = 0;
        // Bypass transfer controls: a listing is itself the organizer-approved
        // resale channel, and its price was capped at listing time.
        _tokenApprovals[tokenId] = address(0);
        _balances[seller] -= 1;
        _balances[msg.sender] += 1;
        _owners[tokenId] = msg.sender;
        emit Transfer(seller, msg.sender, tokenId);
        emit Resold(tokenId, seller, msg.sender, price);
        (bool ok,) = seller.call{value: price}("");
        if (!ok) revert TransferFailed(seller, price);
    }

    // ------------------------------------------------------------------------
    // Redemption (single-use check-in)
    // ------------------------------------------------------------------------

    function redeem(uint256 tokenId) external {
        // ownerOf reverts for nonexistent tokens; redemption does not move
        // the ticket, it only marks it used.
        ownerOf(tokenId);
        uint256 eventId = tokenEvent[tokenId];
        if (!checkers[eventId][msg.sender]) revert NotChecker();
        if (redeemed[tokenId]) revert TicketAlreadyRedeemed();
        redeemed[tokenId] = true;
        emit Redeemed(tokenId, eventId, msg.sender);
    }
}
