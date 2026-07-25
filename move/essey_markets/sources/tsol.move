/// Test collateral coin for the Essey SOL market (devnet demo; mintable via TreasuryCap).
module essey_markets::tsol {
    use sui::coin::{Self, TreasuryCap};
    public struct TSOL has drop {}
    fun init(w: TSOL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 9, b"tSOL", b"SOL", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TSOL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
