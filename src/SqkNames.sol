// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SqkNames
/// @notice Name registry for the `.sqk` ending: `bona.sqk` is registered as the label `bona`.
///         Each name is an ERC-721 (tokenId = uint256(keccak256(label))), paid for in $SQK,
///         with expiry, renewal, address/text records and forward-confirmed reverse lookup.
/// @dev Labels are ASCII only (a-z, 0-9, single hyphens inside), which rules out homoglyph spoofing.
contract SqkNames is ERC721, Ownable2Step {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ config
    IERC20 public immutable sqk;
    address public treasury;

    uint256 public constant MIN_LABEL_LENGTH = 3;
    uint256 public constant MAX_LABEL_LENGTH = 63;
    uint256 public constant MIN_DURATION = 365 days;
    uint256 public constant GRACE_PERIOD = 30 days;
    uint256 public constant MIN_COMMITMENT_AGE = 60;
    uint256 public constant MAX_COMMITMENT_AGE = 1 days;

    /// @dev $SQK (in token units) per year for 3-char, 4-char and 5+-char labels.
    uint256[3] public pricePerYear;

    // ----------------------------------------------------------------- storage
    mapping(uint256 id => uint64) public expiries;
    mapping(uint256 id => string) public labelOf;
    mapping(bytes32 commitment => uint256) public commitments;

    // Records are versioned so they reset on transfer and on re-registration.
    mapping(uint256 id => uint256) public recordVersion;
    mapping(uint256 id => mapping(uint256 version => address)) private _addr;
    mapping(uint256 id => mapping(uint256 version => mapping(string key => string))) private _text;

    mapping(address account => string) private _primary;

    // ------------------------------------------------------------------ events
    event NameRegistered(string label, uint256 indexed id, address indexed owner, uint256 expires, uint256 cost);
    event NameRenewed(string label, uint256 indexed id, uint256 expires, uint256 cost);
    event AddrChanged(uint256 indexed id, address addr);
    event TextChanged(uint256 indexed id, string indexed indexedKey, string key, string value);
    event PrimaryNameSet(address indexed account, string label);
    event PricesChanged(uint256[3] pricePerYear);
    event TreasuryChanged(address treasury);

    // ------------------------------------------------------------------ errors
    error InvalidLabel();
    error NotAvailable();
    error DurationTooShort();
    error CommitmentMissing();
    error CommitmentTooNew();
    error CommitmentTooOld();
    error NotNameOwner();
    error NameExpired();
    error ZeroAddress();

    constructor(IERC20 sqk_, address treasury_, address admin, uint256[3] memory pricePerYear_)
        ERC721("SQK Names", "SQKN")
        Ownable(admin)
    {
        if (address(sqk_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        sqk = sqk_;
        treasury = treasury_;
        pricePerYear = pricePerYear_;
    }

    // ------------------------------------------------------------- label rules
    function idOf(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function valid(string memory label) public pure returns (bool) {
        bytes memory b = bytes(label);
        uint256 len = b.length;
        if (len < MIN_LABEL_LENGTH || len > MAX_LABEL_LENGTH) return false;
        if (b[0] == "-" || b[len - 1] == "-") return false;
        for (uint256 i; i < len; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-";
            if (!ok) return false;
            if (c == "-" && b[i + 1] == "-") return false; // i+1 is in range: last char is never "-"
        }
        return true;
    }

    // --------------------------------------------------------------- lifecycle
    /// @notice True if the label can be registered right now (never registered, or past its grace period).
    function available(string memory label) public view returns (bool) {
        return valid(label) && expiries[idOf(label)] + GRACE_PERIOD < block.timestamp;
    }

    /// @notice Price in $SQK to register or renew `label` for `duration` seconds.
    function price(string memory label, uint256 duration) public view returns (uint256) {
        uint256 len = bytes(label).length;
        uint256 perYear = len == 3 ? pricePerYear[0] : len == 4 ? pricePerYear[1] : pricePerYear[2];
        return (perYear * duration) / 365 days;
    }

    function makeCommitment(string memory label, address owner_, bytes32 secret) public pure returns (bytes32) {
        return keccak256(abi.encode(label, owner_, secret));
    }

    /// @notice Step 1: commit to a registration so it can't be front-run.
    function commit(bytes32 commitment) external {
        commitments[commitment] = block.timestamp;
    }

    /// @notice Step 2: reveal, pay in $SQK (caller must have approved this contract) and register.
    function register(string calldata label, address owner_, uint256 duration, bytes32 secret) external {
        if (!available(label)) revert NotAvailable();
        if (duration < MIN_DURATION) revert DurationTooShort();

        bytes32 c = makeCommitment(label, owner_, secret);
        uint256 madeAt = commitments[c];
        if (madeAt == 0) revert CommitmentMissing();
        if (madeAt + MIN_COMMITMENT_AGE > block.timestamp) revert CommitmentTooNew();
        if (madeAt + MAX_COMMITMENT_AGE < block.timestamp) revert CommitmentTooOld();
        delete commitments[c];

        uint256 id = idOf(label);
        if (_ownerOf(id) != address(0)) _burn(id); // lapsed name: clear the old owner

        uint256 cost = price(label, duration);
        uint64 expires = uint64(block.timestamp + duration);
        expiries[id] = expires;
        labelOf[id] = label;
        ++recordVersion[id];
        _mint(owner_, id);

        if (cost > 0) sqk.safeTransferFrom(msg.sender, treasury, cost);
        emit NameRegistered(label, id, owner_, expires, cost);
    }

    /// @notice Anyone may renew any name (handy for gifting). Works until the grace period ends.
    function renew(string calldata label, uint256 duration) external {
        uint256 id = idOf(label);
        uint256 current = expiries[id];
        if (current == 0 || current + GRACE_PERIOD < block.timestamp) revert NotAvailable();
        if (duration < MIN_DURATION) revert DurationTooShort();

        uint256 cost = price(label, duration);
        uint64 expires = uint64(current + duration);
        expiries[id] = expires;

        if (cost > 0) sqk.safeTransferFrom(msg.sender, treasury, cost);
        emit NameRenewed(label, id, expires, cost);
    }

    // ----------------------------------------------------------------- records
    function setAddr(string calldata label, address a) external {
        uint256 id = idOf(label);
        _setAddr(id, a);
    }

    function setText(string calldata label, string calldata key, string calldata value) external {
        uint256 id = idOf(label);
        _requireLiveOwner(id);
        _text[id][recordVersion[id]][key] = value;
        emit TextChanged(id, key, key, value);
    }

    function _setAddr(uint256 id, address a) internal {
        _requireLiveOwner(id);
        _addr[id][recordVersion[id]] = a;
        emit AddrChanged(id, a);
    }

    function _requireLiveOwner(uint256 id) internal view {
        if (_ownerOf(id) != msg.sender) revert NotNameOwner();
        if (expiries[id] < block.timestamp) revert NameExpired();
    }

    // -------------------------------------------------------------- resolution
    /// @notice Resolve `bona` (for bona.sqk) to an address. Zero if unset or expired.
    function resolve(string calldata label) external view returns (address) {
        uint256 id = idOf(label);
        if (expiries[id] < block.timestamp) return address(0);
        return _addr[id][recordVersion[id]];
    }

    function text(string calldata label, string calldata key) external view returns (string memory) {
        uint256 id = idOf(label);
        if (expiries[id] < block.timestamp) return "";
        return _text[id][recordVersion[id]][key];
    }

    function ownerOfLabel(string calldata label) external view returns (address) {
        uint256 id = idOf(label);
        return expiries[id] < block.timestamp ? address(0) : _ownerOf(id);
    }

    // ----------------------------------------------------------------- reverse
    /// @notice Pick the name shown for your address. Only counts if the name resolves back to you.
    function setPrimaryName(string calldata label) external {
        _primary[msg.sender] = label;
        emit PrimaryNameSet(msg.sender, label);
    }

    /// @notice Forward-confirmed reverse lookup: returns "" unless `label` is live and resolves to `account`.
    function nameOf(address account) external view returns (string memory) {
        string memory label = _primary[account];
        if (bytes(label).length == 0) return "";
        uint256 id = idOf(label);
        if (expiries[id] < block.timestamp) return "";
        return _addr[id][recordVersion[id]] == account ? label : "";
    }

    // ------------------------------------------------------------------- admin
    function setPrices(uint256[3] calldata p) external onlyOwner {
        pricePerYear = p;
        emit PricesChanged(p);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasuryChanged(t);
    }

    // --------------------------------------------------------------- overrides
    /// @dev Transfers reset records so a new owner never inherits the old owner's address or text.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0) && to != address(0)) ++recordVersion[tokenId];
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return string.concat("https://names.sqk/meta/", labelOf[id], ".sqk");
    }
}
