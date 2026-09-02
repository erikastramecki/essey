import { concatHex, encodeAbiParameters, keccak256 } from "viem";

// Must stay byte-identical to HolderDistributor._settle / leafOf (src/market/HolderDistributor.sol:263,:315):
//   keccak256(bytes.concat(keccak256(abi.encode(epoch, holder, token, amount))))
// and to OpenZeppelin MerkleProof's commutative pair hash. test/HolderAirdropRoot.t.sol pins both against
// the real contract from a committed fixture; changing either side without that test is how a root goes dead.
const LEAF_ARGS = [{ type: "uint256" }, { type: "address" }, { type: "address" }, { type: "uint256" }];

export function leafHash({ epoch, holder, token, amount }) {
  const inner = keccak256(encodeAbiParameters(LEAF_ARGS, [BigInt(epoch), holder, token, BigInt(amount)]));
  return keccak256(inner);
}

export function hashPair(a, b) {
  return BigInt(a) < BigInt(b) ? keccak256(concatHex([a, b])) : keccak256(concatHex([b, a]));
}

/// Sorted-leaf tree with odd nodes promoted unchanged. Returns { root, layers }.
export function buildTree(leaves) {
  if (leaves.length === 0) throw new Error("merkle: empty leaf set");
  const sorted = [...leaves].sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0));
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] === sorted[i - 1]) throw new Error(`merkle: duplicate leaf ${sorted[i]}`);
  }
  const layers = [sorted];
  while (layers[layers.length - 1].length > 1) {
    const prev = layers[layers.length - 1];
    const next = [];
    for (let i = 0; i < prev.length; i += 2) {
      next.push(i + 1 < prev.length ? hashPair(prev[i], prev[i + 1]) : prev[i]);
    }
    layers.push(next);
  }
  return { root: layers[layers.length - 1][0], layers };
}

export function proofFor(tree, leaf) {
  let index = tree.layers[0].indexOf(leaf);
  if (index < 0) throw new Error(`merkle: leaf not in tree ${leaf}`);
  const proof = [];
  for (let d = 0; d < tree.layers.length - 1; d++) {
    const layer = tree.layers[d];
    const sibling = index % 2 === 0 ? index + 1 : index - 1;
    if (sibling < layer.length) proof.push(layer[sibling]);
    index = Math.floor(index / 2);
  }
  return proof;
}

export function verifyProof(leaf, proof, root) {
  let node = leaf;
  for (const sibling of proof) node = hashPair(node, sibling);
  return node === root;
}
