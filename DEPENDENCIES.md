# Solidity dependencies

Dependencies are vendored from the official repositories at the exact revisions below. Each
directory includes a `REVISION` file and the upstream license. Upstream production sources are
unmodified; repository history, development tools and full test suites are omitted.

| Directory | Upstream | Version / pinned commit |
| --- | --- | --- |
| `lib/v4-periphery` | https://github.com/Uniswap/v4-periphery | Package 1.0.4, `dce236d4e2057422d0791d9a973a58765eb46f65` |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | Package 1.0.2, `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` |
| `lib/permit2` | https://github.com/Uniswap/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | 5.0.2, `dbb6104ce834628e473d2173bbc9d47f81a9eec3` |
| `lib/solmate` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | Existing local dependency, package 1.16.1 |

Core and Permit2 match the periphery repository's submodule revisions. OpenZeppelin and Solmate
match that core revision's submodule revisions, as in the upstream periphery remappings.

`lib/permit2/test/utils/DeployPermit2.sol` is also copied unchanged from the pinned Permit2
repository. Integration tests use this upstream helper to install the actual precompiled Permit2
runtime at its canonical address. This avoids importing Permit2's exact Solidity 0.8.17 source
into Solidity 0.8.26 tests. The helper is only used for testing.

V4 core carries upstream BUSL-1.1 and MIT licenses by file. The remaining libraries retain their
upstream license notices; see the files in each dependency directory.
