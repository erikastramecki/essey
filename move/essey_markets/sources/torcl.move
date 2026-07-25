/// Test collateral coin for the Essey ORCL market (devnet demo; mintable via TreasuryCap).
module essey_markets::torcl {
    use sui::coin::{Self, TreasuryCap};
    public struct TORCL has drop {}
    fun init(w: TORCL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tORCL", b"Oracle xStock", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TORCL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
