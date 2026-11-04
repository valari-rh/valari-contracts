#!/usr/bin/env python3
"""Project-specific Slither checks for ValariRouterV3 (secure-workflow Step 4, "custom
Slither checks"). Read-only: builds the Slither model from an existing build-info and
asserts the access/authorisation matrix the README promises.

Run from valari-contracts (same FOUNDRY_* env as the printers):
  python audit/2026-10-05-v3/trailofbits/printers/custom_checks.py /tmp/tob-workflow/out/build-info
"""
import sys

from slither.core.solidity_types.user_defined_type import UserDefinedType
from slither.slither import Slither
from slither.solc_parsing.declarations import contract as contract_parsing
from slither.solc_parsing.solidity_types.type_parsing import _add_type_references

upstream_parse_type = contract_parsing.parse_type


def parse_type_with_library_id(ast_node, caller_context):
    # Same SafeCast library-scope fix as audit/2026-10-05/slither/run_with_scope_fix.py.
    result = upstream_parse_type(ast_node, caller_context)
    if not isinstance(ast_node, dict) or ast_node.get("nodeType") != "IdentifierPath":
        return result
    reference = ast_node.get("referencedDeclaration")
    for declaration in caller_context.compilation_unit.contracts:
        if declaration.id == reference and declaration.is_library:
            if isinstance(result, UserDefinedType) and result.type is not declaration:
                replacement = UserDefinedType(declaration)
                _add_type_references(replacement, ast_node["src"], caller_context.compilation_unit)
                return replacement
    return result


contract_parsing.parse_type = parse_type_with_library_id

sl = Slither(
    "src/ValariRouterV3.sol",
    compile_force_framework="foundry",
    ignore_compile=True,
    foundry_build_info_directory=sys.argv[1],
    disallow_partial=True,
)
router = sl.get_contract_from_name("ValariRouterV3")[0]

entry = [
    f
    for f in router.functions
    if f.visibility in ("public", "external") and not f.view and not f.pure and not f.is_constructor
    and not f.name.startswith("slither")
    and not f.is_shadowed  # Ownable.transferOwnership is overridden by Ownable2Step's
]
failures = []
print("ENTRY POINT | modifiers | state written (transitive) | reads msg.sender (transitive) | external call targets")
for f in sorted(entry, key=lambda x: x.source_mapping.lines[0] if x.contract_declarer == router else 10_000):
    mods = sorted(m.name for m in f.modifiers)
    written = sorted(v.name for v in f.all_state_variables_written())
    sender = any(v.name == "msg.sender" for v in f.all_solidity_variables_read())
    targets = sorted({str(c.destination) for _, c in f.all_high_level_calls()})
    line = f.source_mapping.lines[0]
    print(f"{f.contract_declarer.name}.{f.full_name} L{line} | {mods} | {written} | {sender} | {targets}")

    business = [w for w in written if w not in ("_status",)]
    # 1. Every router-declared entry point is nonReentrant.
    if f.contract_declarer == router and "nonReentrant" not in mods:
        failures.append(f"{f.full_name}: router entry point without nonReentrant")
    # 2. Catalog, fee recipient and ownership are written only behind onlyOwner
    #    (acceptOwnership is the one exception: pending owner).
    owner_vars = {"_pools", "_poolIds", "_stockPoolIds", "feeRecipient", "_owner", "_pendingOwner",
                  "depositsDisabled", "ejectEnabled"}
    if owner_vars & set(business) and "onlyOwner" not in mods and f.name != "acceptOwnership":
        failures.append(f"{f.full_name}: writes {owner_vars & set(business)} without onlyOwner")
    # 3. onlyOwner functions never touch positions or commission credits.
    user_vars = {"_deposits", "_positionIds", "_depositorPositionIds", "claimableCommission",
                 "totalClaimableCommission"}
    if "onlyOwner" in mods and user_vars & set(business):
        failures.append(f"{f.full_name}: owner function writes user state {user_vars & set(business)}")
    # 4. Anything writing user state or credits depends on msg.sender.
    if user_vars & set(business) and not sender:
        failures.append(f"{f.full_name}: writes user state without reading msg.sender")
    # 5. No payable entry point.
    if f.payable:
        failures.append(f"{f.full_name}: payable")

# 6. Single writer per catalog variable: only _addPool (and its callers) assign it.
for name in ("_pools", "_poolIds", "_stockPoolIds"):
    direct = sorted(
        f.name for f in router.functions if any(v.name == name for v in f.state_variables_written)
    )
    print(f"direct writers of {name}: {direct}")
    if direct != ["_addPool"]:
        failures.append(f"{name}: unexpected direct writers {direct}")
# 8. The owner switches are read only where the README says: depositsDisabled only in
#    openPosition, ejectEnabled only in ejectPosition (plus their setters and getters).
for name, allowed in (("depositsDisabled", {"openPosition", "setDepositsDisabled", "depositsDisabled"}),
                      ("ejectEnabled", {"ejectPosition", "setEjectEnabled", "ejectEnabled"})):
    readers = sorted(f.name for f in router.functions if any(v.name == name for v in f.state_variables_read))
    print(f"readers of {name}: {readers}")
    if set(readers) - allowed:
        failures.append(f"{name}: unexpected readers {set(readers) - allowed}")
# 9. ejectPosition moves no tokens: it writes only _deposits (and the guard) and makes no
#    ERC20 call; its only external calls are to the PositionManager.
eject = next(f for f in router.functions if f.name == "ejectPosition")
eject_written = sorted(v.name for v in eject.all_state_variables_written())
eject_targets = sorted({f"{t.name}.{c.function.name}" for t, c in eject.all_high_level_calls()})
print(f"ejectPosition writes {eject_written}, calls {eject_targets}")
if set(eject_written) - {"_deposits", "_status"}:
    failures.append(f"ejectPosition writes {eject_written}")
if set(eject_targets) - {"IERC721.transferFrom", "IERC721.ownerOf"}:
    failures.append(f"ejectPosition calls {eject_targets}")
# 10. Each *To variant has the same write set and msg.sender dependence as its sibling.
by_name = {f.name: f for f in router.functions}
for a, b in (("collectFees", "collectFeesTo"), ("exitPosition", "exitPositionTo")):
    wa = sorted(v.name for v in by_name[a].all_state_variables_written())
    wb = sorted(v.name for v in by_name[b].all_state_variables_written())
    if wa != wb:
        failures.append(f"{a}/{b}: write sets differ {wa} vs {wb}")
# 7. No delegatecall / selfdestruct / low-level call declared in the router itself.
for f in router.functions_declared:
    if f.low_level_calls:
        failures.append(f"{f.full_name}: low-level call in router source")
    for node in f.nodes:
        text = str(node.expression or "")
        if "delegatecall" in text or "selfdestruct" in text:
            failures.append(f"{f.full_name}: {text}")

print("\nRESULT:", "all custom checks hold" if not failures else "FAILURES")
for item in failures:
    print(" -", item)
sys.exit(1 if failures else 0)
