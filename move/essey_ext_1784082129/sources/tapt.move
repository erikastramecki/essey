/// Test collateral coin for the Essey APT market (devnet demo; mintable via TreasuryCap).
module essey_ext_1784082129::tapt {
    use sui::coin::{Self, TreasuryCap};
    public struct TAPT has drop {}
    fun init(w: TAPT, ctx: &mut TxContext) {
        let (t, mt) = coin::create_currency(w, 8, b"tAPT", b"Aptos", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAPT>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
