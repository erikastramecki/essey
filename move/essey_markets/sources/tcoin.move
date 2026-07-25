/// Test collateral coin for the Essey COIN market (devnet demo; mintable via TreasuryCap).
module essey_markets::tcoin {
    use sui::coin::{Self, TreasuryCap};
    public struct TCOIN has drop {}
    fun init(w: TCOIN, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tCOIN", b"Coinbase xStock", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TCOIN>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
