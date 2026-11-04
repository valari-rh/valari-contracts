#!/usr/bin/env python3
"""Symbolic checks of ValariRouterV3 with Manticore 0.3.7.

Run compile.sh first, then:  python run.py <scenario> [timeout-seconds]

Scope, stated plainly: Manticore executes the UNMODIFIED router source compiled for the
Istanbul EVM (it cannot run Cancun bytecode), against stand-in managers (Mocks.sol), with an
empty pool catalog. That covers the router's dispatcher, argument decoding, access control,
ownership, fee-recipient and catalog logic for ONE symbolic call. It does not cover
deposits, collection or exits, which need the real v4 managers; those are covered by the
Foundry and Echidna suites. Gas is not modelled.

In the outsider, treasury and pending scenarios the selector is symbolic but constrained to
exclude the router's view functions: they contain no storage write (Slither's write matrix),
and their symbolic-size array allocations do not terminate in Manticore. What remains is
every state-changing entry point with arbitrary arguments, plus every unknown selector.

Scenarios
  outsider   any call from an account with no role cannot change router storage
  treasury   the same for the commission recipient
  value      any call carrying 1 wei reverts (no payable entry point)
  pending    the pending owner can change storage only through acceptOwnership
  recipient  owner's setFeeRecipient(x): x is stored, and is never 0 or the router
  addpool    owner's addPool(key): every accepted key satisfies the listing rules
"""
import json
import sys
import time
import warnings

warnings.filterwarnings("ignore")

from manticore.core.plugin import Plugin  # noqa: E402
from manticore.core.smtlib import Operators  # noqa: E402
from manticore.ethereum import ManticoreEVM  # noqa: E402
from manticore.utils import config  # noqa: E402

BUILD = "/tmp/valari-manticore-20261014/out"
WORD = 32
# Storage layout from `forge inspect ValariRouterV3 storageLayout`.
SLOT_STATUS, SLOT_OWNER, SLOT_PENDING, SLOT_RECIPIENT, SLOT_POOL_IDS = 0, 1, 2, 3, 7
STATE_CHANGING = (
    "openPosition(bytes32,uint128,uint128,int24,int24,uint128,uint160,uint160,uint256)",
    "collectFees(uint256,uint256)",
    "collectFeesTo(uint256,address,uint256)",
    "exitPosition(uint256,uint128,uint128,uint256)",
    "exitPositionTo(uint256,address,uint128,uint128,uint256)",
    "ejectPosition(uint256,address)",
    "collectForEject(uint256,address)",
    "withdrawCommission(address,address,uint256)",
    "addPool((address,address,uint24,int24,address))",
    "setDepositsDisabled(bytes32,bool)",
    "setEjectEnabled(bytes32,bool)",
    "setFeeRecipient(address)",
    "transferOwnership(address)",
    "acceptOwnership()",
    "renounceOwnership()",
)
ADDRESS_MASK = (1 << 160) - 1


class StorageWrites(Plugin):
    """Records every SSTORE so a path's effect on the router can be judged exactly."""

    def did_evm_write_storage_callback(self, state, address, offset, value):
        state.context.setdefault("writes", []).append((address, offset, value))


def word(value):
    return int(value).to_bytes(WORD, "big")


def artifact(source, name):
    return json.load(open(f"{BUILD}/{source}/{name}.json"))


def creation_code(name):
    return bytes.fromhex(artifact("Mocks.sol", name)["bytecode"]["object"][2:])


def router_runtime(immutables):
    """The router's runtime code with its immutables filled in, as its constructor leaves it.

    Manticore cannot get through the 21 KB creation transaction in useful time, so the router
    account is created with this code and the three storage slots the constructor writes.
    The same construction was checked against a real deployment on a local chain: identical
    code, and storage {0: 1, 1: deployer, 3: deployer}.
    """
    built = artifact("ValariRouterV3.sol", "ValariRouterV3")
    code = bytearray(bytes.fromhex(built["deployedBytecode"]["object"][2:]))
    references = built["deployedBytecode"]["immutableReferences"]
    # AST ids ascend in declaration order: positionManager, stateView, poolManager, permit2, usdg.
    assert len(references) == len(immutables) == 5
    for ast_id, value in zip(sorted(references, key=int), immutables):
        for reference in references[ast_id]:
            assert reference["length"] == WORD
            code[reference["start"] : reference["start"] + WORD] = word(value)
    return bytes(code), built["methodIdentifiers"]


def selector(hashes, signature):
    return bytes.fromhex(hashes[signature])


def setup(scenario):
    evm = config.get_group("evm")
    evm.oog = "ignore"
    if scenario == "addpool":
        # Keep keccak(PoolKey) symbolic so the key itself stays symbolic through validation.
        evm.sha3 = evm.sha3.symbolicate
    config.get_group("core").procs = 8
    # A solver timeout is reported as an infeasible path ("Forking on unfeasible constraint
    # set") and silently drops it; give Z3 room, especially on a busy machine.
    config.get_group("smt").timeout = 900
    m = ManticoreEVM(workspace_url="mem:")
    m.verbosity(0)
    m.register_plugin(StorageWrites())

    owner = m.create_account(balance=10**21, name="owner")
    treasury = m.create_account(balance=10**21, name="treasury")
    pending = m.create_account(balance=10**21, name="pending")
    outsider = m.create_account(balance=10**21, name="outsider")

    code = creation_code("MockCode")
    pool_manager = m.create_contract(owner=owner, init=code, name="poolManager")
    permit2 = m.create_contract(owner=owner, init=code, name="permit2")
    usdg = m.create_contract(owner=owner, init=code, name="usdg")
    stock_a = m.create_contract(owner=owner, init=code, name="stockA")
    stock_b = m.create_contract(owner=owner, init=code, name="stockB")
    pm_code = creation_code("MockPositionManager")
    position_manager = m.create_contract(
        owner=owner,
        init=pm_code + word(int(pool_manager)) + word(int(permit2)),
        name="positionManager",
    )
    sv_code = creation_code("MockStateView")
    state_view = m.create_contract(
        owner=owner, init=sv_code + word(int(pool_manager)), name="stateView"
    )
    runtime, hashes = router_runtime(
        [int(position_manager), int(state_view), int(pool_manager), int(permit2), int(usdg)]
    )
    router = m.create_account(balance=0, code=runtime, name="router")
    for state in m.ready_states:
        state.platform.set_storage_data(int(router), SLOT_STATUS, 1)
        state.platform.set_storage_data(int(router), SLOT_OWNER, int(owner))
        state.platform.set_storage_data(int(router), SLOT_RECIPIENT, int(owner))
    assert m.count_ready_states() == 1, "router setup failed"

    m.transaction(
        caller=owner,
        address=router,
        value=0,
        data=selector(hashes, "setFeeRecipient(address)") + word(int(treasury)),
    )
    m.transaction(
        caller=owner,
        address=router,
        value=0,
        data=selector(hashes, "transferOwnership(address)") + word(int(pending)),
    )
    assert m.count_ready_states() == 1, "setup transactions failed"
    accounts = dict(
        owner=owner,
        treasury=treasury,
        pending=pending,
        outsider=outsider,
        usdg=usdg,
        stock_a=stock_a,
        stock_b=stock_b,
        router=router,
        position_manager=position_manager,
        state_view=state_view,
        pool_manager=pool_manager,
        permit2=permit2,
    )
    for state in m.ready_states:
        base = {
            slot: state.solve_one(state.platform.get_storage_data(int(router), slot))
            for slot in (SLOT_STATUS, SLOT_OWNER, SLOT_PENDING, SLOT_RECIPIENT, SLOT_POOL_IDS)
        }
        state.context["writes"] = []
    assert base[SLOT_OWNER] == int(owner) and base[SLOT_PENDING] == int(pending)
    assert base[SLOT_RECIPIENT] == int(treasury) and base[SLOT_STATUS] == 1
    assert base[SLOT_POOL_IDS] == 0
    return m, accounts, hashes, base


def slot_value(state, router, slot):
    return state.platform.get_storage_data(int(router), slot)


def router_writes(state, router):
    return [w for w in state.context.get("writes", []) if w[0] == int(router)]


def solved_selector(state, data):
    return state.solve_one(data[:4]).hex()


def main():
    scenario = sys.argv[1]
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 3600
    started = time.time()
    m, acct, hashes, base = setup(scenario)
    router = acct["router"]
    names = {value: key for key, value in hashes.items()}
    violations = []
    succeeded = {}
    notes = {}

    if scenario in ("outsider", "treasury", "value", "pending"):
        caller = acct[{"value": "outsider"}.get(scenario, scenario)]
        # Selector plus nine words: as long as the router's widest entry point (openPosition).
        data = m.make_symbolic_buffer(4 + 9 * WORD)
        if scenario != "value":
            assert all(signature in hashes for signature in STATE_CHANGING)
            views = [sel for signature, sel in hashes.items() if signature not in STATE_CHANGING]
            called = Operators.CONCAT(32, *data[:4])
            for view in views:
                m.constrain(called != int(view, 16))
            notes["view_selectors_excluded"] = len(views)
        with m.kill_timeout(timeout):
            m.transaction(
                caller=caller, address=router, value=1 if scenario == "value" else 0, data=data
            )
        for state in m.ready_states:
            sel = solved_selector(state, data)
            name = names.get(sel, "0x" + sel)
            succeeded[name] = succeeded.get(name, 0) + 1
            writes = router_writes(state, router)
            if scenario == "value":
                violations.append(f"call with value succeeded: {name}")
                continue
            if scenario == "pending" and writes:
                # The only legitimate change: this caller becomes owner.
                ok = (
                    sel == hashes["acceptOwnership()"]
                    and state.must_be_true(
                        slot_value(state, router, SLOT_OWNER) == int(acct["pending"])
                    )
                    and state.must_be_true(slot_value(state, router, SLOT_PENDING) == 0)
                    and state.must_be_true(
                        slot_value(state, router, SLOT_RECIPIENT) == base[SLOT_RECIPIENT]
                    )
                    and state.must_be_true(
                        slot_value(state, router, SLOT_POOL_IDS) == base[SLOT_POOL_IDS]
                    )
                    and state.must_be_true(slot_value(state, router, SLOT_STATUS) == 1)
                )
                if not ok:
                    violations.append(f"pending owner changed state through {name}")
                continue
            if writes:
                violations.append(f"{scenario} wrote router storage through {name}")
            for slot, expected in base.items():
                if state.can_be_true(slot_value(state, router, slot) != expected):
                    violations.append(f"{scenario} changed slot {slot} through {name}")

    elif scenario == "recipient":
        argument = m.make_symbolic_buffer(WORD)
        data = selector(hashes, "setFeeRecipient(address)") + argument
        with m.kill_timeout(timeout):
            m.transaction(caller=acct["owner"], address=router, value=0, data=data)
        for state in m.ready_states:
            succeeded["setFeeRecipient(address)"] = succeeded.get("setFeeRecipient(address)", 0) + 1
            stored = slot_value(state, router, SLOT_RECIPIENT)
            passed = Operators.CONCAT(256, *argument)
            if state.can_be_true(stored != passed):
                violations.append("stored recipient differs from the argument")
            if state.can_be_true(stored == 0):
                violations.append("zero recipient accepted")
            if state.can_be_true(stored == int(router)):
                violations.append("router accepted as its own recipient")
            if state.can_be_true(slot_value(state, router, SLOT_OWNER) != base[SLOT_OWNER]):
                violations.append("setFeeRecipient changed the owner")

    elif scenario == "addpool":
        key = m.make_symbolic_buffer(5 * WORD)
        data = selector(hashes, "addPool((address,address,uint24,int24,address))") + key
        with m.kill_timeout(timeout):
            m.transaction(caller=acct["owner"], address=router, value=0, data=data)
        fields = [Operators.CONCAT(256, *key[i * WORD : (i + 1) * WORD]) for i in range(5)]
        currency0, currency1, _fee, spacing, hooks = fields
        with_code = [
            int(acct[n])
            for n in (
                "usdg",
                "stock_a",
                "stock_b",
                "router",
                "position_manager",
                "state_view",
                "pool_manager",
                "permit2",
            )
        ]
        usdg = int(acct["usdg"])
        for state in m.ready_states:
            succeeded["addPool"] = succeeded.get("addPool", 0) + 1
            rules = {
                "currency0 < currency1": Operators.ULT(currency0, currency1),
                "hooks == 0": hooks == 0,
                "one side is USDG": Operators.OR(currency0 == usdg, currency1 == usdg),
                "1 <= tickSpacing <= 32767": Operators.AND(
                    Operators.UGE(spacing, 1), Operators.ULE(spacing, 32767)
                ),
                "currency0 has code": Operators.OR(*[currency0 == a for a in with_code]),
                "currency1 has code": Operators.OR(*[currency1 == a for a in with_code]),
            }
            for rule, holds in rules.items():
                if not state.must_be_true(holds):
                    violations.append(f"accepted a key violating: {rule}")
            if not state.must_be_true(slot_value(state, router, SLOT_POOL_IDS) == 1):
                violations.append("catalog length is not 1 after one addPool")
            # Non-interference is judged from the write log, not by re-reading slots: with
            # keccak kept symbolic, the solver cannot tell a mapping slot from slot 1, so a
            # read-back would report every low slot as "possibly changed".
            fixed, hashed = set(), 0
            for _address, offset, _value in router_writes(state, router):
                candidates = state.solve_n(offset, 2)
                if len(candidates) == 1:
                    fixed.add(candidates[0])
                else:
                    hashed += 1
            notes["fixed_slots_written"] = sorted(hex(slot) for slot in fixed)
            notes["keccak_derived_writes"] = hashed
            for slot in (SLOT_OWNER, SLOT_PENDING, SLOT_RECIPIENT):
                if slot in fixed:
                    violations.append(f"addPool wrote slot {slot}")
            if not state.must_be_true(slot_value(state, router, SLOT_STATUS) == 1):
                violations.append("reentrancy guard left set after addPool")
    else:
        raise SystemExit(f"unknown scenario {scenario}")

    result = dict(
        scenario=scenario,
        succeeded_paths=m.count_ready_states(),
        reverted_or_failed_paths=m.count_terminated_states(),
        killed_paths=m.count_killed_states(),
        timed_out=m.is_killed(),
        succeeded_by_function=succeeded,
        violations=sorted(set(violations)),
        notes=notes,
        seconds=round(time.time() - started, 1),
    )
    print(json.dumps(result, indent=1))
    sys.exit(1 if violations or m.is_killed() else 0)


if __name__ == "__main__":
    main()
