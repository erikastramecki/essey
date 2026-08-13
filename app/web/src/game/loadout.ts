// The EIP-712 loadout signature — reconciled to the AS-BUILT MissionBoard (which absorbed the
// sketch's LoadoutRegistry): domain name "DON-Loadout" v1, verifyingContract = MissionBoard,
// and the struct mirrors LOADOUT_TYPEHASH (MissionBoard.sol L92-93) EXACTLY:
//   Loadout(uint256 donId,uint64 briefId,uint256 provision,bytes32 garrisonHash,uint256 nonce,uint256 deadline)
// garrisonHash = keccak256(abi.encode(garrisonHitterIds, salt))  (the commit half, checked by
// RaidEngine.revealGarrison with the same abi.encode shape)
import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";
import { pub, NET, GAME_ADDR, gameWallet } from "./gameChain";
import { missionBoardAbi } from "./gameAbi";

export type Loadout = {
  donId: bigint;
  briefId: bigint;
  provision: bigint;
  garrisonHash: Hex;
  nonce: bigint;
  deadline: bigint;
};

export const LOADOUT_TYPES = {
  Loadout: [
    { name: "donId", type: "uint256" },
    { name: "briefId", type: "uint64" },
    { name: "provision", type: "uint256" },
    { name: "garrisonHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export const loadoutDomain = () => ({
  name: "DON-Loadout",
  version: "1",
  chainId: NET.chainId,
  verifyingContract: GAME_ADDR.loadoutRegistry, // = MissionBoard (consolidated as-built)
} as const);

/// 32 random bytes from the browser CSPRNG — the garrison/raid commit salt.
export function randomSalt(): Hex {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return ("0x" + Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("")) as Hex;
}

/// The garrison commit half: keccak256(abi.encode(hitterIds, salt)) — MissionBoard Loadout doc +
/// RaidEngine.revealGarrison check. abi.encode, NOT encodePacked.
export function garrisonCommit(hitterIds: bigint[], salt: Hex): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: "uint256[]" }, { type: "bytes32" }],
    [hitterIds, salt],
  ));
}

/// The raid commit preimage: keccak256(abi.encode(attackerDonId, hitterIds, targetDonId, salt))
/// — RaidEngine.reveal's CommitMismatch check, verbatim. No mode, no raider address as-built.
export function raidCommitHash(attackerDonId: bigint, hitterIds: bigint[], targetDonId: bigint, salt: Hex): Hex {
  return keccak256(encodeAbiParameters(
    [{ type: "uint256" }, { type: "uint256[]" }, { type: "uint256" }, { type: "bytes32" }],
    [attackerDonId, hitterIds, targetDonId, salt],
  ));
}

/// Next usable per-Don nonce: lastSettledNonce(donId) + 1 (monotonic per token; the getter lives
/// on MissionBoard, keyed by donId alone). Falls back to now-ms when unreadable — still monotonic.
export async function nextNonce(donId: bigint): Promise<bigint> {
  try {
    const last = await pub.readContract({
      address: GAME_ADDR.missionBoard, abi: missionBoardAbi,
      functionName: "lastSettledNonce", args: [donId],
    });
    return last + 1n;
  } catch {
    return BigInt(Date.now());
  }
}

/// Build the depart loadout. Client default deadline ≈ 24h (cheap to re-sign).
export async function buildLoadout(
  donId: bigint, briefId: bigint, provision: bigint, garrisonHash: Hex,
): Promise<Loadout> {
  return {
    donId, briefId, provision, garrisonHash,
    nonce: await nextNonce(donId),
    deadline: BigInt(Math.floor(Date.now() / 1000) + 24 * 3600),
  };
}

/// Sign the loadout through the user's selected wallet (eth_signTypedData_v4 under the hood).
export async function signLoadout(account: Address, l: Loadout): Promise<Hex> {
  return gameWallet(account).signTypedData({
    account,
    domain: loadoutDomain(),
    types: LOADOUT_TYPES,
    primaryType: "Loadout",
    message: l,
  });
}
