// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Bell} from "../market/Bell.sol";

/// Minimal read surface of the TravelVoucher we raffle: the USD value locked into a voucher at issue.
interface IVoucherValue {
    function lockedValue(uint256 id) external view returns (uint256);
}

/// TravelCase — the Gotcha box for travel. Buy a Case in $ESSEY, draw a real, fully-backed TravelVoucher
/// (a predefined trip whose USDG value is locked at issue). Keep it, sell it back for cash, or redeem it for
/// the trip — all of which happen on the VOUCHER itself, not here.
///
/// This is the travel prize class dropped into the SAME machine as `EsseyCases`: the identical blockhash
/// commit-reveal draw, keeper-openable, floor-on-expiry, and Bell fee routing. It is a SEPARATE contract
/// (not a parameter on EsseyCases) on purpose — the prize is a non-fungible, self-solvent ERC721, whose
/// backing and pricing model don't share EsseyCases's fungible-ERC20-lot + oracle accounting. Keeping it thin
/// is only possible BECAUSE the voucher already owns its solvency (`reserve() >= reserved`) and its exits
/// (`sellBack`/`redeem`, spread → Bell). This contract does one job: hold, draw, and deliver a voucher.
///
/// ENTROPY — same bound as EsseyCases, and STRICTLY WEAKER selection surface. The draw seed is the blockhash
/// of a block committed at buy (`drawBlock = block.number + 1`), unpredictable AT BUY, public afterwards. The
/// honest bound on every post-draw lever (open-timing within the 256-block window, expired-claim timing) is
/// the DISPERSION of prize values in inventory. EsseyCases must actively manage that dispersion because its
/// prize values DRIFT with the market. Here the values are LOCKED at issue and never move, so the dispersion
/// is exactly the fixed tier mix the bankroll seeds — there is no drift to select on. As with EsseyCases, the
/// moment prizes are made deliberately non-uniform enough that blockhash bias matters, this must move to a
/// hardened VRF; for a fixed low-variance tier set on a testnet it is the accepted, simpler entropy.
///
/// DOUBLE-LAYERED SOLVENCY. `buy` reverts unless the on-chain voucher inventory exceeds unopened Cases, so
/// every unopened Case is backed by a real voucher already held here — and that voucher is itself backed 1:1
/// by USDG in the TravelVoucher contract. "The house reserved a fully-funded trip before you opened" is an
/// invariant at both layers.
///
/// ROLES. `bankroll` can only ADD inventory (seed vouchers it owns). It can never withdraw, reprice, or touch
/// a user's Case. Treasury/keeper are immutable. No owner, pause, or upgrade — vouchers committed to the game
/// stay in the game until a buyer draws them.
contract TravelCase is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Case {
        address buyer;
        uint64 drawBlock; // blockhash(drawBlock) seeds the draw; openable when block.number > drawBlock
        uint64 boughtAt; // purchase timestamp; expired-claim and abandonment sweep key off this
        bool opened;
    }

    IERC20 public immutable essey; // Case price currency (access token — sunk to treasury)
    IERC20 public immutable base; // buy-fee currency == Bell.reward(), so the fee feeds the pot
    Bell public immutable bell;
    IERC721 public immutable voucher; // the TravelVoucher collection we raffle
    address public immutable treasury;
    address public immutable bankroll;
    /// Optional convenience settler: may open a Case on the buyer's behalf, prize ALWAYS to the stored buyer.
    /// It cannot withdraw, reprice, or touch funds; the buyer can always open/claimExpired themselves. Zero =>
    /// buyer-only. See EsseyCases for the full keeper rationale — it is identical here.
    address public immutable keeper;

    uint256 public immutable casePrice; // flat $ESSEY price of one Case
    uint256 public immutable buyFee; // base-token fee on buy
    uint256 public immutable boosterShareBps; // share of the buy fee routed to the Bell

    uint256 internal constant BPS = 10_000;
    /// How long an EXPIRED case stays claimable (at the floor) before anyone may sweep it back to the pool —
    /// same bound and rationale as EsseyCases: it caps the expired-claim option so a patient buyer can't sit
    /// on an American option over the inventory floor.
    uint256 internal constant CLAIM_TTL = 7 days;

    uint256[] private _tokenIds; // voucher inventory (uniform draw)
    mapping(uint256 => Case) public cases;
    uint256 public nextCaseId;
    uint256 public unopened; // Cases bought but not yet opened — each must be voucher-backed

    event VouchersSeeded(uint256 count);
    event CaseBought(uint256 indexed caseId, address indexed buyer, uint64 drawBlock);
    event CaseOpened(uint256 indexed caseId, address indexed buyer, uint256 tokenId);
    event ExpiredClaimed(uint256 indexed caseId, address indexed buyer, uint256 tokenId);
    event CaseSwept(uint256 indexed caseId, address indexed buyer);
    event FeeRouted(uint256 toBell, uint256 toTreasury);

    error BadConfig();
    error NotBankroll();
    error NoBackingInventory();
    error NotYourCase();
    error AlreadyOpened();
    error DrawNotReady();
    error DrawExpired();
    error DrawNotExpired();
    error ClaimLapsed();
    error WrongCollection();

    constructor(
        IERC20 essey_,
        Bell bell_,
        IERC721 voucher_,
        address treasury_,
        address bankroll_,
        uint256 casePrice_,
        uint256 buyFee_,
        uint256 boosterShareBps_,
        address keeper_
    ) {
        if (
            address(essey_) == address(0) || address(bell_) == address(0) || address(voucher_) == address(0)
                || treasury_ == address(0) || bankroll_ == address(0) || casePrice_ == 0 || boosterShareBps_ > BPS
        ) revert BadConfig();
        // The buy-fee asset must be the Bell's reward token so routing to the Bell is a plain transfer that
        // grows the pot — and it must differ from the access token.
        IERC20 base_ = IERC20(address(bell_.reward()));
        if (essey_ == base_) revert BadConfig();

        essey = essey_;
        bell = bell_;
        base = base_;
        voucher = voucher_;
        treasury = treasury_;
        bankroll = bankroll_;
        casePrice = casePrice_;
        buyFee = buyFee_;
        boosterShareBps = boosterShareBps_;
        keeper = keeper_; // zero is allowed: buyer-only opens
    }

    // ---------------------------------------------------------------- views

    function inventoryCount() external view returns (uint256) {
        return _tokenIds.length;
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return _tokenIds[i];
    }

    /// The backing invariant, exposed: vouchers not yet spoken for by an unopened Case.
    function freeInventory() public view returns (uint256) {
        return _tokenIds.length - unopened; // buy() maintains _tokenIds.length >= unopened
    }

    // ---------------------------------------------------------------- inventory (bankroll, add-only)

    /// Accept incoming vouchers ONLY from the collection we raffle — this lets `seed` pull via
    /// `safeTransferFrom`, and rejects any other NFT so junk can never enter. It does NOT register inventory
    /// (that is `seed`'s job), so a voucher sent here by a path OTHER than `seed` is simply a donor's mistake:
    /// it is owned but not drawable, harmless to the game's accounting.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(voucher)) revert WrongCollection();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// Seed the prize pool: the bankroll deposits vouchers it already owns (minted to it via
    /// `TravelVoucher.issue`). Add-only — there is no withdraw. Each id is pulled in and registered as a
    /// drawable prize. Mixed tiers are fine and intended: that mix IS the gacha's variance.
    function seed(uint256[] calldata ids) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        for (uint256 i = 0; i < ids.length; i++) {
            voucher.safeTransferFrom(msg.sender, address(this), ids[i]); // hook above vets the collection
            _tokenIds.push(ids[i]);
        }
        emit VouchersSeeded(ids.length);
    }

    // ---------------------------------------------------------------- buy / open

    /// Buy a Case: $ESSEY price → treasury, buy fee → Bell/treasury split. Reverts unless a real voucher
    /// exists in inventory beyond those already owed to unopened Cases.
    function buy() external nonReentrant returns (uint256 caseId) {
        if (_tokenIds.length < unopened + 1) revert NoBackingInventory();
        unopened += 1;
        caseId = nextCaseId++;
        uint64 drawBlock = uint64(block.number + 1);
        cases[caseId] = Case(msg.sender, drawBlock, uint64(block.timestamp), false);

        essey.safeTransferFrom(msg.sender, treasury, casePrice);
        _takeFee(buyFee);
        emit CaseBought(caseId, msg.sender, drawBlock);
    }

    /// Open a Case: the committed blockhash seeds a uniform draw over the voucher inventory; the drawn voucher
    /// is delivered to the BUYER. Callable by the buyer or the keeper (prize always to the stored buyer).
    function open(uint256 caseId) external nonReentrant returns (uint256 tokenId) {
        Case storage c = cases[caseId];
        if (c.buyer == address(0) || (msg.sender != c.buyer && msg.sender != keeper)) revert NotYourCase();
        if (c.opened) revert AlreadyOpened();
        if (block.number <= c.drawBlock) revert DrawNotReady();
        bytes32 bh = blockhash(c.drawBlock);
        if (bh == bytes32(0)) revert DrawExpired(); // past the 256-block window — claimExpired instead

        c.opened = true;
        unopened -= 1;
        uint256 idx = uint256(keccak256(abi.encodePacked(bh, caseId))) % _tokenIds.length;
        tokenId = _drawOut(idx);

        voucher.transferFrom(address(this), c.buyer, tokenId);
        emit CaseOpened(caseId, c.buyer, tokenId);
    }

    /// Claim a Case whose draw block fell out of the 256-block blockhash window. NOT a re-roll: an expired
    /// case pays out the CURRENT LOWEST-value voucher in inventory (by locked USD value), and only until
    /// CLAIM_TTL — so abandoning a draw can never beat the floor. Because voucher values are static, the floor
    /// here is a plain minimum with no oracle or session gating (unlike EsseyCases).
    function claimExpired(uint256 caseId) external nonReentrant returns (uint256 tokenId) {
        Case storage c = cases[caseId];
        if (c.buyer != msg.sender) revert NotYourCase();
        if (c.opened) revert AlreadyOpened();
        if (block.number <= c.drawBlock || blockhash(c.drawBlock) != bytes32(0)) revert DrawNotExpired();
        if (block.timestamp > c.boughtAt + CLAIM_TTL) revert ClaimLapsed();

        c.opened = true;
        unopened -= 1;
        tokenId = _drawOut(_lowestValueIndex());

        voucher.transferFrom(address(this), msg.sender, tokenId);
        emit ExpiredClaimed(caseId, msg.sender, tokenId);
    }

    /// Free the backing of a Case whose expired-claim window has ALSO lapsed. Anyone may call it: the buyer
    /// forfeited by ignoring both the open window and the CLAIM_TTL; the voucher simply stays in the pool
    /// (nothing transferred), and freeing `unopened` lets new Cases be bought against it again. Both clocks
    /// must have lapsed — same block-halt reasoning as EsseyCases.
    function sweepAbandoned(uint256 caseId) external {
        Case storage c = cases[caseId];
        if (c.buyer == address(0)) revert NotYourCase(); // nonexistent
        if (c.opened) revert AlreadyOpened();
        if (block.number <= c.drawBlock || blockhash(c.drawBlock) != bytes32(0)) revert DrawNotExpired();
        if (block.timestamp <= c.boughtAt + CLAIM_TTL) revert DrawNotExpired();
        c.opened = true;
        unopened -= 1;
        emit CaseSwept(caseId, c.buyer);
    }

    // ---------------------------------------------------------------- internals

    /// Swap-and-pop the drawn index out of inventory, returning its tokenId.
    function _drawOut(uint256 idx) internal returns (uint256 tokenId) {
        tokenId = _tokenIds[idx];
        _tokenIds[idx] = _tokenIds[_tokenIds.length - 1];
        _tokenIds.pop();
    }

    /// Index of the lowest locked-value voucher in inventory. No oracle/session: voucher values are locked at
    /// issue and static, and every held voucher is live (this contract never burns its own inventory), so
    /// `lockedValue` is a stable positive read.
    function _lowestValueIndex() internal view returns (uint256 best) {
        uint256 n = _tokenIds.length; // >= 1: the claiming case was unopened, so backing exists
        uint256 bestVal = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            uint256 v = IVoucherValue(address(voucher)).lockedValue(_tokenIds[i]);
            if (v < bestVal) {
                bestVal = v;
                best = i;
            }
        }
    }

    /// Buy-fee routing — identical to the Exchange/Cases: booster share grows the Bell pot by plain transfer
    /// of the reward token, remainder to treasury.
    function _takeFee(uint256 fee) internal {
        if (fee == 0) return;
        base.safeTransferFrom(msg.sender, address(this), fee);
        uint256 toBell = (fee * boosterShareBps) / BPS;
        if (toBell != 0) base.safeTransfer(address(bell), toBell);
        uint256 toTreasury = fee - toBell;
        if (toTreasury != 0) base.safeTransfer(treasury, toTreasury);
        emit FeeRouted(toBell, toTreasury);
    }
}
