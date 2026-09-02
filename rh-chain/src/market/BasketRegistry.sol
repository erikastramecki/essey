// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IConverter} from "./IConverter.sol";

/// BasketRegistry — the governed, append-only catalogue the holder-airdrop keeper reads to know which
/// stocks the USDG pot may buy and which named baskets a holder may sign a preference for. No hardcoded
/// tickers: every stock is an address, eligible only if the StockConverter already routes it. Every add
/// is TIMELOCKED and IRREVERSIBLE — a proposed stock or basket is public for the delay before it can
/// accrue, and once committed it can never be mutated or removed, so a holder can exit a basket before a
/// questionable constituent activates and a listed stock's routing can't be swapped underneath anyone.
///
/// Per-holder basket PREFERENCE is NOT stored here — it is a gasless signed message the keeper reads
/// off-chain (Floor's model). This contract only fixes the shared catalogue both sides agree on.
contract BasketRegistry {
    IConverter public immutable converter; // a stock is addable only if this already supports it
    uint256 public immutable timelock; // public-review delay between propose and commit
    address public governor; // proposes/commits adds; can only renounce, never mutate a committed entry

    struct Basket {
        string name;
        address[] tokens;
        uint16[] bps; // Σ == BPS
        uint256 eta; // earliest commit time
        bool committed;
    }

    mapping(address => bool) public isRegisteredStock;
    mapping(address => uint256) public stockEta; // 0 = not proposed
    address[] public stockList;

    Basket[] internal _baskets; // index = basketId; append-only

    uint256 internal constant BPS = 10_000;

    event GovernorRenounced();
    event StockProposed(address indexed token, uint256 eta);
    event StockCommitted(address indexed token);
    event BasketProposed(uint256 indexed id, string name, uint256 eta);
    event BasketCommitted(uint256 indexed id);

    error NotGovernor();
    error ZeroAddress();
    error ZeroTimelock();
    error NotSupported();
    error AlreadyProposed();
    error AlreadyRegistered();
    error NothingPending();
    error TimelockNotElapsed();
    error BadWeights();
    error UnknownBasket();
    error AlreadyCommitted();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IConverter converter_, address governor_, uint256 timelock_) {
        if (address(converter_) == address(0) || governor_ == address(0)) revert ZeroAddress();
        if (timelock_ == 0) revert ZeroTimelock();
        converter = converter_;
        governor = governor_;
        timelock = timelock_;
    }

    // ---------------------------------------------------------------- stocks (append-only, timelocked)

    function proposeStock(address token) external onlyGovernor {
        if (token == address(0)) revert ZeroAddress();
        if (isRegisteredStock[token]) revert AlreadyRegistered();
        if (stockEta[token] != 0) revert AlreadyProposed();
        if (!converter.isSupported(token)) revert NotSupported();
        uint256 eta = block.timestamp + timelock;
        stockEta[token] = eta;
        emit StockProposed(token, eta);
    }

    function commitStock(address token) external onlyGovernor {
        uint256 eta = stockEta[token];
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotElapsed();
        if (isRegisteredStock[token]) revert AlreadyRegistered();
        isRegisteredStock[token] = true;
        stockList.push(token);
        emit StockCommitted(token);
    }

    // ---------------------------------------------------------------- baskets (append-only, timelocked)

    /// Propose a named weighted set of already-registered stocks (Σ bps == BPS). Frozen at commit.
    function proposeBasket(string calldata name, address[] calldata tokens, uint16[] calldata bps)
        external
        onlyGovernor
        returns (uint256 id)
    {
        uint256 n = tokens.length;
        if (n == 0 || bps.length != n) revert BadWeights();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (!isRegisteredStock[tokens[i]]) revert NotSupported();
            sum += bps[i];
        }
        if (sum != BPS) revert BadWeights();
        id = _baskets.length;
        _baskets.push(Basket({name: name, tokens: tokens, bps: bps, eta: block.timestamp + timelock, committed: false}));
        emit BasketProposed(id, name, _baskets[id].eta);
    }

    function commitBasket(uint256 id) external onlyGovernor {
        if (id >= _baskets.length) revert UnknownBasket();
        Basket storage b = _baskets[id];
        if (b.committed) revert AlreadyCommitted();
        if (block.timestamp < b.eta) revert TimelockNotElapsed();
        b.committed = true;
        emit BasketCommitted(id);
    }

    /// One-way: renounce governance so the catalogue can only ever grow, never be re-pointed. Irreversible.
    function renounceGovernor() external onlyGovernor {
        governor = address(0);
        emit GovernorRenounced();
    }

    // ---------------------------------------------------------------- views

    function stockCount() external view returns (uint256) {
        return stockList.length;
    }

    function basketCount() external view returns (uint256) {
        return _baskets.length;
    }

    function isCommittedBasket(uint256 id) external view returns (bool) {
        return id < _baskets.length && _baskets[id].committed;
    }

    function basketOf(uint256 id)
        external
        view
        returns (string memory name, address[] memory tokens, uint16[] memory bps, bool committed)
    {
        if (id >= _baskets.length) revert UnknownBasket();
        Basket storage b = _baskets[id];
        return (b.name, b.tokens, b.bps, b.committed);
    }
}
