// Writes config/robinhood-curated.json: the catalog ValariRouterV3 is deployed with,
// which is exactly the pools the Valari frontend lists (../valari/src/lib/pools.json),
// in the frontend's order. Every pool must also be in the full 100-pool catalog
// (config/robinhood.json), and each id is recomputed from its key.
//
//   node tools/curated-catalog.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const FRONTEND = resolve(here, '../../valari');
const { ethers } = await import(resolve(FRONTEND, 'node_modules/ethers/lib.esm/index.js'));

const full = JSON.parse(readFileSync(resolve(here, '../config/robinhood.json'), 'utf8'));
const listed = JSON.parse(readFileSync(resolve(FRONTEND, 'src/lib/pools.json'), 'utf8'));
const known = new Map(full.pools.map((p) => [p.poolId.toLowerCase(), p]));
const KEY = 'tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)';
const coder = ethers.AbiCoder.defaultAbiCoder();

const pools = listed.markets.map((m) => {
  const k = m.pool;
  const key = { currency0: k.currency0.toLowerCase(), currency1: k.currency1.toLowerCase(), fee: k.fee, tickSpacing: k.tickSpacing, hooks: k.hooks.toLowerCase() };
  const id = ethers.keccak256(coder.encode([KEY], [key]));
  if (id !== k.id.toLowerCase()) throw new Error(`${m.symbol}: pool id ${k.id} does not match its key (${id})`);
  if (!known.has(id)) throw new Error(`${m.symbol}: pool ${id} is not in config/robinhood.json`);
  if (key.currency0 !== full.usdg && key.currency1 !== full.usdg) throw new Error(`${m.symbol}: neither side is USDG`);
  return { symbol: m.symbol, poolId: id, ...key };
});
if (new Set(pools.map((p) => p.poolId)).size !== pools.length) throw new Error('duplicate pool');

const out = {
  chainId: full.chainId,
  poolManager: full.poolManager,
  positionManager: full.positionManager,
  stateView: full.stateView,
  permit2: full.permit2,
  usdg: full.usdg,
  source: 'valari/src/lib/pools.json (the frontend\'s listed markets), subset of config/robinhood.json',
  frontendReadAt: listed.readAt,
  poolIds: pools.map((p) => p.poolId),
  poolKeysAbi: coder.encode([`${KEY}[]`], [pools.map(({ currency0, currency1, fee, tickSpacing, hooks }) => ({ currency0, currency1, fee, tickSpacing, hooks }))]),
  pools,
};
writeFileSync(resolve(here, '../config/robinhood-curated.json'), JSON.stringify(out, null, 2) + '\n');
console.log(`${pools.length} curated pools: ${pools.map((p) => p.symbol).join(' ')}`);
