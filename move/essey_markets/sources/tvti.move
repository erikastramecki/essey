/// Test collateral coin for the Essey VTI market (devnet demo; mintable via TreasuryCap).
module essey_markets::tvti {
    use sui::coin::{Self, TreasuryCap};
    public struct TVTI has drop {}
    fun init(w: TVTI, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tVTI", b"Total Market xStock", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TVTI>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
