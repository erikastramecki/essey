/// Test collateral coin for the Essey QCOM market (devnet demo; mintable via TreasuryCap).
module essey_markets::tqcom {
    use sui::coin::{Self, TreasuryCap};
    public struct TQCOM has drop {}
    fun init(w: TQCOM, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tQCOM", b"Qualcomm xStock", b"Essey devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TQCOM>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
