/// Test collateral coin for the Essey DOT market (devnet demo; mintable via TreasuryCap).
module essey_ext_1784082129::tdot {
    use sui::coin::{Self, TreasuryCap};
    public struct TDOT has drop {}
    fun init(w: TDOT, ctx: &mut TxContext) {
        let (t, mt) = coin::create_currency(w, 8, b"tDOT", b"Polkadot", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TDOT>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
