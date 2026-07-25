/// Test collateral coin for the Essey ARB market (devnet demo; mintable via TreasuryCap).
module essey_ext_1784082129::tarb {
    use sui::coin::{Self, TreasuryCap};
    public struct TARB has drop {}
    fun init(w: TARB, ctx: &mut TxContext) {
        let (t, mt) = coin::create_currency(w, 8, b"tARB", b"Arbitrum", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TARB>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
