/// <reference types="vite/client" />

// circomlibjs ships no type declarations; declare the minimal surface poolsdk uses.
declare module "circomlibjs" {
  export interface PoseidonField {
    toString(x: unknown): string;
  }
  export interface Poseidon {
    (inputs: bigint[]): unknown;
    F: PoseidonField;
  }
  export function buildPoseidon(): Promise<Poseidon>;
}

// snarkjs ships no type declarations; declare the minimal surface poolsdk uses.
declare module "snarkjs" {
  export const groth16: {
    fullProve(
      input: unknown,
      wasm: string,
      zkey: string,
    ): Promise<{ proof: unknown; publicSignals: string[] }>;
    verify(vkey: unknown, publicSignals: string[], proof: unknown): Promise<boolean>;
    exportSolidityCallData(proof: unknown, publicSignals: string[]): Promise<string>;
  };
}
