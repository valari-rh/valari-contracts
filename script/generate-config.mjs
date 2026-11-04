// Rebuild deployment inputs from Valari's verified 100-stock catalog.
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { loadCatalog, USDG } from '../../ui/server/catalog.mjs';

const require = createRequire(new URL('../../ui/package.json', import.meta.url));
const { AbiCoder, keccak256 } = require('ethers');
const catalog = loadCatalog();
if (catalog.chainId !== 4663 || catalog.pools.length !== 100) throw Error('Expected 100 Robinhood pools.');
const keyType = 'tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)';
const coder = AbiCoder.defaultAbiCoder();
const keys = catalog.pools.map(pool => {
  if (pool.hooks !== '0x' + '00'.repeat(20)) throw Error(`Hook pool unsupported: ${pool.symbol}`);
  const key = [pool.token0, pool.token1, pool.fee, pool.tickSpacing, pool.hooks];
  if (keccak256(coder.encode([keyType], [key])) !== pool.id) throw Error(`Pool ID mismatch: ${pool.symbol}`);
  return key;
});
const config = {
  chainId: 4663,
  poolManager: '0x8366a39cc670b4001a1121b8f6a443a643e40951',
  positionManager: '0x58daec3116aae6d93017baaea7749052e8a04fa7',
  stateView: '0xf3334192d15450cdd385c8b70e03f9a6bd9e673b',
  permit2: '0x000000000022d473030f116ddee9f6b43ac78ba3',
  usdg: USDG,
  poolIds: catalog.pools.map(pool => pool.id),
  // Explicit ABI bytes avoid JSON-object key-order ambiguity in Foundry decoding.
  poolKeysAbi: coder.encode([keyType + '[]'], [keys]),
  pools: catalog.pools.map((pool, i) => ({
    symbol: pool.symbol, poolId: pool.id, currency0: keys[i][0], currency1: keys[i][1],
    fee: keys[i][2], tickSpacing: keys[i][3], hooks: keys[i][4],
  })),
};
const directory = new URL('../config/', import.meta.url);
await fs.mkdir(directory, { recursive: true });
await fs.writeFile(new URL('robinhood.json', directory), JSON.stringify(config, null, 2) + '\n');
console.log(`Wrote ${keys.length} verified pool keys to config/robinhood.json`);
