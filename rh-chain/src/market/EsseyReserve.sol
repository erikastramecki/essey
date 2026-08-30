// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// $ESSEY's supply-reducing burn. DEPLOY INVARIANTS (not enforceable on-chain — verify at deploy):
/// (1) $ESSEY is FIXED-SUPPLY / non-mintable, so cumulative redeemed can never exceed `claimBase` —
/// if more could be minted, `claimedShares` could pass `claimBase` and break the solvency bound.
/// (2) `burn()` genuinely reduces totalSupply (EsseyToken is ERC20Burnable). A lying burn only stops
/// the display supply from shrinking; the redemption math keys off the immutable claimBase, not it.
interface IEsseyBurnable {
  function burn(uint256 amount) external;
}

/// EsseyReserve — the equity-pegged FLOOR under $ESSEY. It holds ANY tokens sent to it; holding $ESSEY
/// is a redeemable pro-rata claim on that pile, in-kind. Backing GROWS without bound: fee streams and
/// FLOOR distributions deposit stock here, and each deposit ratchets the floor for everyone.
///
/// FULLY ADMINLESS. No owner, no registrar, no roles, no setters, no withdraw, no upgrade, no pause.
/// The ONLY things this contract can do with a token are (a) accept a deposit and (b) pay a holder's
/// own pro-rata slice out on redemption. There is nothing to trust and no key to compromise. NAV,
/// token legitimacy, and bond eligibility all live OFF this contract (a separate valuation layer);
/// the reserve itself never trusts a price and never reasons about which tokens are "real".
///
/// UNBOUNDED TOKENS via a two-step redeem, so the per-token loop that capped the old design is gone:
///   • redeem(e)  — burns your $ESSEY, mints a Receipt for `e`. O(1); cost independent of basket size.
///   • claim(id,token) / claimMany(id,tokens[]) — pulls your slice of the tokens YOU name. Gas is
///     bounded by how many you claim per call, never by how many the reserve holds. Claim across as
///     many calls as you like; the reserve can back $ESSEY with 12 tokens or 12,000.
///
/// ORDER-INDEPENDENT, PROVABLY SOLVENT accounting. A redeem of `e` mints a receipt whose fee-adjusted
/// WEIGHT is `w = e·(BPS-EXIT_FEE_BPS)/BPS` (95% of e). Each token's payout divides by a FIXED
/// denominator `claimBase` (= genesis $ESSEY supply) minus the WEIGHT already claimed against that token
/// — NOT by live circulating supply. The payout numerator AND the denominator decrement are the SAME
/// `w`, so the balance/denominator ratio is invariant under claims: every receipt collects EXACTLY
/// `w/claimBase` of a token's lifetime deposits — whoever claims first, and however a stake is split
/// into receipts (splitting cannot dodge the fee; late claiming cannot recapture it). The forfeited 5%
/// is never claimable by anyone: it stays as permanent OVER-COLLATERALISATION (the bondable surplus and
/// the arbitrage price floor). Since Σw ≤ 0.95·claimBase < claimBase, denom always exceeds w, so every
/// payout ≤ live balance and the reserve can never be over-drawn. Deposits between redeem and claim are
/// shared pro-rata by outstanding receipts — a receipt is a live claim on the evolving pile until pulled.
///
/// The stock legs are third-party UPGRADEABLE tokens with a transfer gate (Robinhood Stock Tokens) that
/// can PAUSE. A paused or misbehaving token must never brick another's claim: each claim isolates its
/// token in a self-call (the balance READ and slice math included) and, on revert or a zero payout,
/// SKIPS without consuming the claim — so the holder simply retries that leg when it unpauses.
contract EsseyReserve is ReentrancyGuard {
  using SafeERC20 for IERC20;

  address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 public constant EXIT_FEE_BPS = 500; // 5% of every claim is forfeited -> permanent over-collateralisation
  uint256 public constant BPS = 10_000;

  IERC20 public immutable essey; // the claim token; never itself part of the backing
  uint256 public immutable claimBase; // fixed denominator: total $ESSEY supply captured at genesis

  struct Receipt {
    address owner;
    uint256 essey; // $ESSEY burned into this receipt; its claim WEIGHT is 0.95·essey (5% exit fee)
  }

  uint256 public receiptCount;
  mapping(uint256 => Receipt) public receipts;
  mapping(uint256 => mapping(address => bool)) public claimed; // receiptId => token => already pulled
  mapping(address => uint256) public claimedShares; // Σ fee-adjusted WEIGHT ever claimed against this token

  event Funded(address indexed from, address indexed token, uint256 amount);
  event Redeemed(uint256 indexed receiptId, address indexed owner, uint256 essey);
  event Claimed(uint256 indexed receiptId, address indexed token, uint256 amount);
  event ClaimSkipped(uint256 indexed receiptId, address indexed token); // paused/empty; retryable

  error ZeroAddress();
  error ZeroSupply();
  error ZeroAmount();
  error NotOwner();
  error OnlySelf();

  constructor(IERC20 _essey) {
    if (address(_essey) == address(0)) revert ZeroAddress();
    essey = _essey;
    claimBase = _essey.totalSupply(); // fixed forever; the shared denominator for every token
    if (claimBase == 0) revert ZeroSupply();
  }

  // ------------------------------------------------------------------ grow the backing

  /// Deposit any token, raising the floor for every holder. Permissionless and token-agnostic — a raw
  /// ERC-20 transfer to this address counts identically (claims read the live balance); `fund` only
  /// adds a clean event for indexers. Spam is harmless: an unwanted token is never counted in NAV
  /// (that gate lives off-contract) and, if nobody claims it, simply sits here inert.
  function fund(address token, uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    emit Funded(msg.sender, token, amount);
  }

  // ------------------------------------------------------------------ redeem -> receipt (O(1))

  /// Burn `esseyAmount` of your $ESSEY and receive a Receipt granting 95% of `esseyAmount/claimBase` of
  /// every token in the reserve (the 5% exit fee stays as over-collateralisation), now and going forward
  /// until you pull each leg. Pays out nothing here — that is `claim`. Approve this contract for
  /// `esseyAmount` first. Receipts are owner-bound.
  function redeem(uint256 esseyAmount) external nonReentrant returns (uint256 receiptId) {
    if (esseyAmount == 0) revert ZeroAmount();
    essey.safeTransferFrom(msg.sender, address(this), esseyAmount);
    _remove(esseyAmount); // out of circulation before any receipt exists (CEI)
    receiptId = receiptCount++;
    receipts[receiptId] = Receipt({owner: msg.sender, essey: esseyAmount});
    emit Redeemed(receiptId, msg.sender, esseyAmount);
  }

  /// Remove redeemed $ESSEY from circulation: burn if supported, else strand at 0xdEaD. Either way it
  /// leaves `circulatingSupply`; the redemption math itself never depends on this (it keys off claimBase).
  function _remove(uint256 amount) internal {
    try IEsseyBurnable(address(essey)).burn(amount) {
      return;
    } catch {
      essey.safeTransfer(DEAD, amount);
    }
  }

  // ------------------------------------------------------------------ claim (per token, O(1) each)

  /// Pull this receipt's slice of one token.
  function claim(uint256 receiptId, address token) external nonReentrant {
    _claimOne(receiptId, token);
  }

  /// Pull this receipt's slice of many tokens in one call — you choose how many, so gas stays bounded
  /// by your list, never by the basket. Duplicates and already-claimed legs are skipped idempotently.
  function claimMany(uint256 receiptId, address[] calldata tokens) external nonReentrant {
    uint256 n = tokens.length;
    for (uint256 i = 0; i < n; i++) _claimOne(receiptId, tokens[i]);
  }

  /// A leg is consumed ONLY on a positive payout. payShare writes `claimed`/`claimedShares` BEFORE its
  /// transfer (CEI), all inside one self-call, so a revert (paused token) or a zero payout (empty/dust)
  /// rolls those writes back and the leg stays retryable when the balance materialises. Because the
  /// consume precedes the outbound transfer, a token that re-enters during its own transfer already sees
  /// the leg claimed and cannot double-pay — belt-and-suspenders on top of the outer nonReentrant guard.
  function _claimOne(uint256 receiptId, address token) internal {
    Receipt storage r = receipts[receiptId];
    if (r.owner != msg.sender) revert NotOwner();
    if (claimed[receiptId][token]) return;
    uint256 w = (r.essey * (BPS - EXIT_FEE_BPS)) / BPS; // fee-adjusted claim weight; forfeited 5% stays
    uint256 denom = claimBase - claimedShares[token]; // weight still owed a slice of this token; > w
    try this.payShare(receiptId, token, msg.sender, w, denom) returns (uint256 paid) {
      if (paid > 0) emit Claimed(receiptId, token, paid);
      else emit ClaimSkipped(receiptId, token);
    } catch {
      emit ClaimSkipped(receiptId, token);
    }
  }

  /// Isolated per-token payout, and the consume-before-transfer point. The balance read, slice math, the
  /// `claimed`/`claimedShares` writes, AND the transfer all live here inside ONE self-call, so a token
  /// that reverts/overflows (or whose transfer fails) rolls the whole leg back — untouched and retryable
  /// — instead of bricking the redemption. Writes precede the transfer (CEI), so a re-entrant claim of
  /// this same leg sees it already consumed. Self-only; a dust/empty leg returns 0 WITHOUT consuming.
  function payShare(uint256 receiptId, address token, address to, uint256 weight, uint256 denom)
    external
    returns (uint256 payout)
  {
    if (msg.sender != address(this)) revert OnlySelf();
    if (denom == 0) return 0; // no weight outstanding (unreachable for a valid receipt; a hard guard)
    uint256 bal = IERC20(token).balanceOf(address(this));
    payout = (bal * weight) / denom;
    if (payout == 0) return 0;
    claimed[receiptId][token] = true; // CEI: consume before the outbound transfer
    claimedShares[token] += weight;
    IERC20(token).safeTransfer(to, payout);
  }

  // ------------------------------------------------------------------ views (display / NAV layer)

  /// What a receipt would pull for one token right now (0 if already claimed, empty, or dust). Pure read
  /// for the UI's "claim all" so it can size legs and skip zeros; may revert for a token whose balanceOf
  /// reverts — the frontend catches that exactly as a live claim would skip it.
  function previewClaim(uint256 receiptId, address token) external view returns (uint256) {
    if (claimed[receiptId][token]) return 0;
    uint256 w = (receipts[receiptId].essey * (BPS - EXIT_FEE_BPS)) / BPS;
    if (w == 0) return 0;
    uint256 denom = claimBase - claimedShares[token];
    if (denom == 0) return 0;
    uint256 bal = IERC20(token).balanceOf(address(this));
    return (bal * w) / denom;
  }

  /// $ESSEY still able to claim the reserve: total minus what's left circulation (dead) minus $ESSEY
  /// donated into the reserve itself. Display/NAV only — redemption keys off the immutable claimBase.
  function circulatingSupply() public view returns (uint256) {
    return essey.totalSupply() - essey.balanceOf(DEAD) - essey.balanceOf(address(this));
  }

  function reserveOf(address token) public view returns (uint256) {
    return IERC20(token).balanceOf(address(this));
  }

  /// GROSS units of `token` backing 1e18 $ESSEY at genesis-supply basis; a redemption pulls 95% of this
  /// (the 5% fee stays). Uses the immutable claimBase, not circulating supply.
  function floorOf(address token) external view returns (uint256) {
    return (reserveOf(token) * 1e18) / claimBase;
  }
}
