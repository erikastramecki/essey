// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Bell} from "./Bell.sol";

/// Dice Protocol / Pyth-Entropy request-side surface (commit-reveal). Live on Robinhood Chain
/// (0xd8a0680e7699526b57140ed4eafdcc7219dc0a0c).
interface IEntropy {
    function getFeeV2(address provider, uint32 gasLimit) external view returns (uint256);
    function requestV2(address provider, bytes32 userRandomNumber, uint32 gasLimit)
        external
        payable
        returns (uint64 sequenceNumber);
}

/// The Pyth-Entropy / Dice consumer pattern: the oracle dispatches a reveal to the EXTERNAL
/// `_entropyCallback` (leading underscore), which gates on the entropy address and hands off to the
/// internal `entropyCallback`. A consumer implements `getEntropy()` + the internal handler. (Naming a
/// single un-underscored `entropyCallback` would NOT be invoked by the real oracle — audit finding.)
abstract contract IEntropyConsumer {
    error NotEntropy();

    function _entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external {
        if (msg.sender != getEntropy()) revert NotEntropy();
        entropyCallback(sequenceNumber, provider, randomNumber);
    }

    function getEntropy() internal view virtual returns (address);
    function entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) internal virtual;
}

/// EsseyCasesDegen — the "degen case": a provably-fair, provably-solvent MULTIPLIER gacha (variant (b)
/// in TOKENOMICS-essey.md). You buy a case; a roll pays `multiplier x referenceValue` in stock, from
/// 0.65x up to a 50x "Gold Bell". Same variance/RoI as StonkBrokers' Broker Box (~90% RTP) — but the
/// odds are on-chain and disclosed, and the payout is backed by real reserved stock BEFORE you open.
/// "The only case system where the odds AND the bankroll are provable."
///
/// FAIRNESS + THE TRUST BOUNDARY (stated honestly). Entropy is Dice Protocol (Pyth-Entropy-compatible
/// two-party commit-reveal): the final random word = combine(user randomness, the provider's hash-chain
/// reveal), Keccak256-verifiable on-chain, and the provider CANNOT change a committed reveal. What the
/// provider CAN do is see an outcome (its reveal is predetermined, the user-random is public) and
/// selectively WITHHOLD a winning reveal. That is inherent to any commit-reveal and is NOT fixable in
/// this contract — so it is a trust assumption, not a proof: the provider is trusted not to censor.
/// The `reclaim` valve bounds the damage (a withheld case settles at the FLOOR multiplier after a
/// timeout, never zero), and withholding is publicly observable, but it does not recover the drawn
/// prize. We do not claim "neither party can bias"; we claim the roll is verifiable and the bankroll
/// is provably solvent.
///
/// PROVABLY SOLVENT, and it's the progression mechanic. The reference payout is denominated in SHARES
/// (a fixed unit of the payout stock), so every buy reserves the WORST CASE (maxMultiplier x reference,
/// in shares) with NO oracle at all; `buy` reverts unless the free reserve covers it. So the 50x is
/// always backed before you pull, and the case is OPEN 24/7 (no market-session gate — the reserve is a
/// share count, not a dollar value). You roll for a multiple of a stock unit; its dollar value floats
/// with the stock, exactly as the fair-value Cases hand you stock units. Payouts are PULL-BASED:
/// settlement credits `owed[buyer]` (it cannot revert, so a paused/blocklisted stock token can never
/// strand a case), and the winner `withdraw`s when able.
///
/// ROLES. `bankroll` can only ADD (seed the stock reserve). `treasury` is immutable. No owner/pause/
/// upgrade. The ladder is immutable once set (disclosed odds can't be swapped under holders).
contract EsseyCasesDegen is ReentrancyGuard, IEntropyConsumer {
    using SafeERC20 for IERC20;

    struct Case {
        address buyer;
        uint256 worstShares; // reserved at buy = maxMultiplier payout; settlement pays a fraction of this
        uint64 boughtAt;
        bool settled;
    }

    IERC20 public immutable essey; // case price currency (sunk to treasury)
    IERC20 public immutable base; // fee currency == Bell.reward(), so fees feed the pot
    Bell public immutable bell;
    address public immutable treasury;
    address public immutable bankroll;
    IEntropy public immutable entropy;
    address public immutable entropyProvider;

    IERC20 public immutable payoutStock; // winnings paid in this; the reserve is held in it
    uint256 public immutable referenceShares; // 1x payout, in payoutStock token units (no oracle needed)
    uint256 public immutable casePrice; // flat $ESSEY price
    uint256 public immutable buyFee; // base-token fee on buy
    uint256 public immutable boosterShareBps; // share of the fee routed to the Bell
    uint32 public immutable callbackGasLimit;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PPM = 1_000_000;
    uint256 public constant RECLAIM_TIMEOUT = 1 hours; // keeper-withhold safety valve

    // The disclosed ladder: multiplier (bps of 1x) per band, selected by `random % PPM < cumPpm[i]`.
    uint256[] public multiplierBps;
    uint256[] public cumPpm; // strictly increasing, last == PPM
    uint256 public immutable maxMultiplierBps; // the reservation basis (largest ladder multiplier)

    mapping(uint64 => Case) public cases; // keyed by the entropy sequence number
    mapping(address => uint256) public owed; // pull-based winnings, in payoutStock shares
    uint256 public reservedShares; // stock reserved for outstanding (unsettled) cases
    uint256 public totalOwed; // stock credited to winners, not yet withdrawn

    event CaseBought(uint64 indexed seq, address indexed buyer, uint256 worstShares);
    event CaseOpened(uint64 indexed seq, address indexed buyer, uint256 multiplierBps, uint256 payoutShares);
    event CaseReclaimed(uint64 indexed seq, address indexed buyer, uint256 payoutShares);
    event Withdrawn(address indexed winner, uint256 shares);
    event ReserveSeeded(uint256 amount);
    event FeeRouted(uint256 toBell, uint256 toTreasury);
    event EthSwept(uint256 amount);

    error BadConfig();
    error NotBankroll();
    error InsufficientBankroll();
    error InsufficientFee();
    error AlreadySettled();
    error NotYetReclaimable();
    error NothingOwed();
    error RefundFailed();

    /// Constructor config (a struct to stay under the stack limit; also cleaner to deploy).
    struct Config {
        IERC20 essey;
        Bell bell;
        address treasury;
        address bankroll;
        IEntropy entropy;
        address entropyProvider;
        IERC20 payoutStock;
        uint256 referenceShares;
        uint256 casePrice;
        uint256 buyFee;
        uint256 boosterShareBps;
        uint32 callbackGasLimit;
        uint256[] multiplierBps;
        uint256[] cumPpm;
    }

    constructor(Config memory c) {
        if (
            address(c.essey) == address(0) || address(c.bell) == address(0)
                || c.treasury == address(0) || c.bankroll == address(0) || address(c.entropy) == address(0)
                || address(c.payoutStock) == address(0) || c.referenceShares == 0 || c.casePrice == 0
                || c.boosterShareBps > BPS || c.callbackGasLimit == 0 || c.multiplierBps.length == 0
                || c.multiplierBps.length != c.cumPpm.length
        ) revert BadConfig();

        IERC20 base_ = IERC20(address(c.bell.reward()));
        if (c.essey == base_ || c.payoutStock == base_ || c.payoutStock == c.essey) revert BadConfig();

        maxMultiplierBps = _validateLadder(c.multiplierBps, c.cumPpm);

        essey = c.essey;
        bell = c.bell;
        base = base_;
        treasury = c.treasury;
        bankroll = c.bankroll;
        entropy = c.entropy;
        entropyProvider = c.entropyProvider;
        payoutStock = c.payoutStock;
        referenceShares = c.referenceShares;
        casePrice = c.casePrice;
        buyFee = c.buyFee;
        boosterShareBps = c.boosterShareBps;
        callbackGasLimit = c.callbackGasLimit;
        multiplierBps = c.multiplierBps;
        cumPpm = c.cumPpm;
    }

    /// Validate the ladder (cumPpm strictly increasing to exactly PPM, positive multipliers) and return
    /// the max multiplier — the reservation basis. Separated to keep the constructor off the stack ceiling.
    function _validateLadder(uint256[] memory m, uint256[] memory cp) internal pure returns (uint256 maxM) {
        for (uint256 i = 0; i < m.length; i++) {
            if (m[i] == 0) revert BadConfig();
            if (i == 0) {
                if (cp[0] == 0) revert BadConfig();
            } else if (cp[i] <= cp[i - 1]) {
                revert BadConfig();
            }
            if (m[i] > maxM) maxM = m[i];
        }
        if (cp[cp.length - 1] != PPM) revert BadConfig();
    }

    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    // ---------------------------------------------------------------- views

    function tierCount() external view returns (uint256) {
        return multiplierBps.length;
    }

    /// Free reserve = stock backing not reserved for outstanding cases and not owed to winners.
    function freeReserve() public view returns (uint256) {
        return payoutStock.balanceOf(address(this)) - reservedShares - totalOwed;
    }

    /// The entropy fee the caller must send with `buy` (ETH).
    function entropyFee() public view returns (uint256) {
        return entropy.getFeeV2(entropyProvider, callbackGasLimit);
    }

    // ---------------------------------------------------------------- bankroll (add-only)

    function seedReserve(uint256 amount) external nonReentrant {
        if (msg.sender != bankroll) revert NotBankroll();
        if (amount == 0) revert BadConfig();
        payoutStock.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveSeeded(amount);
    }

    // ---------------------------------------------------------------- buy / settle / withdraw

    /// Buy a degen case. Reserves the worst-case (50x) payout in shares — a fixed share count, no oracle,
    /// so it works 24/7 — sinks the $ESSEY price, routes the fee to the Bell, and requests randomness.
    /// The keeper's callback settles the roll ~1-3s later (credited to `owed`; `withdraw` to collect).
    /// Send the entropy fee as msg.value (see `entropyFee()`); excess is refunded.
    function buy() external payable nonReentrant returns (uint64 seq) {
        uint256 worstShares = (referenceShares * maxMultiplierBps) / BPS;
        if (worstShares == 0 || freeReserve() < worstShares) revert InsufficientBankroll();
        reservedShares += worstShares;

        essey.safeTransferFrom(msg.sender, treasury, casePrice);
        _takeFee(buyFee);

        uint256 fee = entropyFee();
        if (msg.value < fee) revert InsufficientFee();
        bytes32 userRandom = keccak256(abi.encodePacked(msg.sender, worstShares, blockhash(block.number - 1)));
        seq = entropy.requestV2{value: fee}(entropyProvider, userRandom, callbackGasLimit);

        cases[seq] = Case(msg.sender, worstShares, uint64(block.timestamp), false);
        emit CaseBought(seq, msg.sender, worstShares);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Entropy settlement (internal; the oracle reaches it via `_entropyCallback`). Maps the verified
    /// random word onto the disclosed ladder and CREDITS the payout (pull-based, so it can never revert
    /// on a paused/blocklisted stock token — a settled roll always lands). Releases the reservation.
    function entropyCallback(uint64 sequenceNumber, address, bytes32 randomNumber)
        internal
        override
        nonReentrant
    {
        Case storage c = cases[sequenceNumber];
        if (c.buyer == address(0) || c.settled) revert AlreadySettled();
        c.settled = true;

        uint256 multBps = _multiplierFor(uint256(randomNumber) % PPM);
        uint256 payoutShares = (c.worstShares * multBps) / maxMultiplierBps;
        _release(c.worstShares, c.buyer, payoutShares);
        emit CaseOpened(sequenceNumber, c.buyer, multBps, payoutShares);
    }

    /// Safety valve for a WITHHELD reveal: after the timeout, ANYONE may settle the case at the FLOOR
    /// multiplier (the ladder minimum), with the payout credited to the buyer. Permissionless so an
    /// abandoned case can never lock reserve forever. Never advantageous over a real roll (the floor is
    /// the worst outcome), so it can't be gamed — it only un-sticks a case a keeper failed to fulfill.
    function reclaim(uint64 sequenceNumber) external nonReentrant {
        Case storage c = cases[sequenceNumber];
        if (c.buyer == address(0) || c.settled) revert AlreadySettled();
        if (block.timestamp < c.boughtAt + RECLAIM_TIMEOUT) revert NotYetReclaimable();
        c.settled = true;

        uint256 payoutShares = (c.worstShares * _floorMultiplierBps()) / maxMultiplierBps;
        _release(c.worstShares, c.buyer, payoutShares);
        emit CaseReclaimed(sequenceNumber, c.buyer, payoutShares);
    }

    /// Collect winnings (pull-based). Separate from settlement so a transient token pause/blocklist
    /// can never strand a case — the winner simply withdraws when able.
    function withdraw() external nonReentrant returns (uint256 shares) {
        shares = owed[msg.sender];
        if (shares == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        totalOwed -= shares;
        payoutStock.safeTransfer(msg.sender, shares);
        emit Withdrawn(msg.sender, shares);
    }

    /// Sweep any stranded native ETH to the treasury. Permissionless, treasury-only destination — the
    /// entropy fee is forwarded in full to the oracle, so this normally moves nothing.
    function sweepEth() external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = treasury.call{value: bal}("");
            if (!ok) revert RefundFailed();
            emit EthSwept(bal);
        }
    }

    // ---------------------------------------------------------------- internals

    /// Release a case's reservation and credit its payout to the buyer (pull-based). The unpaid
    /// remainder returns to the free reserve. `payoutShares <= worstShares` by construction, so
    /// `reservedShares`/`totalOwed` accounting stays backed and never underflows.
    function _release(uint256 worstShares, address buyer, uint256 payoutShares) internal {
        reservedShares -= worstShares;
        if (payoutShares > 0) {
            owed[buyer] += payoutShares;
            totalOwed += payoutShares;
        }
    }

    function _multiplierFor(uint256 roll) internal view returns (uint256) {
        uint256 n = cumPpm.length;
        for (uint256 i = 0; i < n; i++) {
            if (roll < cumPpm[i]) return multiplierBps[i];
        }
        return multiplierBps[n - 1]; // unreachable (cumPpm ends at PPM, roll < PPM), safe fallback
    }

    function _floorMultiplierBps() internal view returns (uint256 floorBps) {
        floorBps = multiplierBps[0];
        for (uint256 i = 1; i < multiplierBps.length; i++) {
            if (multiplierBps[i] < floorBps) floorBps = multiplierBps[i];
        }
    }

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
