// Shared constants + config shape for the Essey Sui SDK.
export const CLOCK_ID = "0x6";
export const MODULE = "async_lending";

export interface EsseyConfig {
  /** Published dregg_lending_async package id. */
  pkg: string;
  /** Fully-qualified stable coin type, e.g. `0x…::tusdc::TUSDC`. */
  stableType: string;
  /** The shared Pool<Stable> object id. */
  pool: string;
}

export const target = (pkg: string, fn: string) => `${pkg}::${MODULE}::${fn}` as const;
