Essey Explorer — in-browser solvency proof verification
=======================================================
The /explorer LOANS panel VERIFY button runs snarkjs.groth16.verify in the browser.
It fetches:
  public/proof/solvency_vk.json     -- the solvency circuit verification key (snarkjs format)
  public/proof/loan_<id>.json       -- { "proof": <groth16 proof>, "publicSignals": [<loan commitment>] }

TODO (tracked): the real solvency proof comes from the gnark circuit (circuit/poseidon/SolvencyCircuit).
Its vk/proof must be converted from gnark's serialization to snarkjs' verification_key.json / proof.json
format (the same conversion the Solana verifier needs). Until those files are dropped here, VERIFY
honestly reports "proof not wired". It NEVER shows a passing state unless snarkjs.groth16.verify returns true.
