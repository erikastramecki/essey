// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Bell} from "../market/Bell.sol";
import {TravelVoucher} from "./TravelVoucher.sol";
import {TravelCase} from "./TravelCase.sol";

/// BackedAssetFactory — the self-serve launchpad for USDG-backed tokenized assets.
///
/// A "backed asset" is the primitive: a `TravelVoucher` whose every unit is covered 1:1 by real USDG the
/// OPERATOR deposits (travel packages, gift cards, brand credit, event passes — travel is just the first
/// skin). Anyone — an individual or a company like TravelSwap or CoinVoyage — can `launch` their own line
/// and, optionally, `launchRaffle` a Gotcha box for it that plugs into the SHARED Essey token economy.
///
/// Two properties make this safe to expose permissionlessly:
///   1. ISOLATION. Every launch deploys a FRESH voucher contract owned by its operator (issuer + admin). One
///      operator's backing lives in its own contract and can never be touched by another operator or by this
///      factory — the factory holds no funds and has no withdraw/administer path over anything it deploys.
///   2. SELF-BACKING. A voucher can only be minted by depositing its full USDG backing (enforced in the
///      voucher), so "launching" cannot create an unbacked claim, no matter who calls it.
///
/// Raffles wire into the CANONICAL Essey market: cases are priced in the shared $ESSEY and their buy fee
/// feeds the shared Bell pot, so an operator's product adds volume to the ecosystem rather than forking it.
/// The operator is the raffle's bankroll (add-only inventory), never the factory.
///
/// The registry is append-only and enumerable so a frontend can list every product and every operator's own
/// launches without an off-chain indexer. Listing a product in Essey's CURATED storefront is a separate,
/// deliberately-not-here decision; this contract only makes creation and standalone raffles self-serve.
contract BackedAssetFactory {
    /// Shared, canonical ecosystem wiring every launch inherits. Immutable — a launch can never be pointed at
    /// a rogue stable, token, or fee sink.
    IERC20 public immutable usdg; // the 6-dec backing/settlement stable (real Global Dollar)
    IERC20 public immutable essey; // the shared access token raffles are priced in
    Bell public immutable bell; // the shared fee → reward engine raffle buy-fees feed
    address public immutable treasury; // the shared protocol treasury (raffle case-price + fee remainder)

    struct Product {
        address voucher; // the deployed TravelVoucher (the backed asset)
        address operator; // issuer + admin of that voucher (self-serve owner)
        string name;
        uint64 createdAt;
    }

    struct Raffle {
        address travelCase; // the deployed TravelCase (Gotcha box)
        address voucher; // the product it draws
        address operator; // the raffle's bankroll
        uint64 createdAt;
    }

    Product[] public products;
    Raffle[] public raffles;
    mapping(address => uint256[]) public productsOf; // operator => indices into `products`
    mapping(address => uint256[]) public rafflesOf; // operator => indices into `raffles`
    mapping(address => bool) public isFactoryVoucher; // a voucher this factory deployed (raffle-launch guard)

    event ProductLaunched(
        uint256 indexed id, address indexed operator, address indexed voucher, string name, string symbol
    );
    event RaffleLaunched(uint256 indexed id, address indexed operator, address indexed travelCase, address voucher);

    error ZeroAddress();
    error NotFactoryVoucher();
    error NotOperator();
    error EsseyIsRewardToken();

    constructor(IERC20 usdg_, IERC20 essey_, Bell bell_, address treasury_) {
        if (
            address(usdg_) == address(0) || address(essey_) == address(0) || address(bell_) == address(0)
                || treasury_ == address(0)
        ) revert ZeroAddress();
        // A raffle's TravelCase requires its access token to DIFFER from the Bell's reward token. Enforce it
        // once here so a misconfigured factory fails at deploy, instead of every future launchRaffle reverting.
        if (essey_ == bell_.reward()) revert EsseyIsRewardToken();
        usdg = usdg_;
        essey = essey_;
        bell = bell_;
        treasury = treasury_;
    }

    // ---------------------------------------------------------------- views (frontend enumeration)

    function productCount() external view returns (uint256) {
        return products.length;
    }

    function raffleCount() external view returns (uint256) {
        return raffles.length;
    }

    function productsOfCount(address operator) external view returns (uint256) {
        return productsOf[operator].length;
    }

    function rafflesOfCount(address operator) external view returns (uint256) {
        return rafflesOf[operator].length;
    }

    // ---------------------------------------------------------------- launch

    /// Launch a new backed-asset line. The caller becomes its issuer AND admin — they alone can define tiers
    /// and mint (each mint pulls its full USDG backing from them). `settlement` is where a holder's redemption
    /// sends the backing (e.g. the operator's fulfilment wallet); `spreadRecipient` earns the sell-back
    /// spread. Backing lives in the returned contract, isolated from every other launch and from this factory.
    function launch(
        string calldata name,
        string calldata symbol,
        address settlement,
        uint16 spreadBps,
        address spreadRecipient
    ) external returns (address voucher) {
        // TravelVoucher's own constructor zero-checks settlement/issuer/admin/spreadRecipient and caps the
        // spread, so a bad config reverts the deploy rather than registering a broken product.
        TravelVoucher v =
            new TravelVoucher(name, symbol, usdg, settlement, msg.sender, msg.sender, spreadBps, spreadRecipient);

        uint256 id = products.length;
        products.push(Product({voucher: address(v), operator: msg.sender, name: name, createdAt: uint64(block.timestamp)}));
        productsOf[msg.sender].push(id);
        isFactoryVoucher[address(v)] = true;
        emit ProductLaunched(id, msg.sender, address(v), name, symbol);
        return address(v);
    }

    /// Launch a Gotcha box (raffle) for a voucher THIS factory previously deployed, wired into the shared
    /// $ESSEY + Bell economy. Two guards: `voucher` must be a factory voucher (so the raffle can never be
    /// pointed at an arbitrary or unbacked collection — its `lockedValue` is trustworthy), AND the caller must
    /// be that voucher's operator (its immutable `issuer`), so no one can register a raffle that enumerates
    /// under someone else's branded product. The caller becomes the raffle's bankroll (the sole, add-only
    /// inventory-seeding role); `keeper` is a separate address the caller chooses (zero => buyer-only opens).
    /// Seeding is a separate operator step (mint vouchers → approve → seed), so this only stands the box up.
    function launchRaffle(address voucher, uint256 casePrice, uint256 buyFee, uint256 boosterShareBps, address keeper)
        external
        returns (address travelCase)
    {
        if (!isFactoryVoucher[voucher]) revert NotFactoryVoucher();
        if (TravelVoucher(voucher).issuer() != msg.sender) revert NotOperator();

        TravelCase c = new TravelCase(
            essey, bell, IERC721(voucher), treasury, msg.sender, casePrice, buyFee, boosterShareBps, keeper
        );

        uint256 id = raffles.length;
        raffles.push(
            Raffle({travelCase: address(c), voucher: voucher, operator: msg.sender, createdAt: uint64(block.timestamp)})
        );
        rafflesOf[msg.sender].push(id);
        emit RaffleLaunched(id, msg.sender, address(c), voucher);
        return address(c);
    }
}
