"""Probe unchanged Cancun bytecode in Manticore; this is NOT a completed audit.

Runs a legacy-EVM positive control, then ValariRouter's poolCount() entrypoint.
Runtime is loaded verbatim, with empty storage and unpatched immutable slots.
That setup only tests whether the engine can execute the bytecode. It does not
model a valid deployment, and must not be used for security conclusions.
"""
import argparse
import hashlib
import importlib.metadata
import json
import platform
from pathlib import Path

from manticore.core.plugin import Plugin
from manticore.ethereum import ManticoreEVM
from manticore.ethereum.detectors import (
    DetectIntegerOverflow,
    DetectInvalid,
    DetectReentrancySimple,
    DetectUnusedRetVal,
)
from manticore.utils import config
from manticore.utils.enums import MProcessingType


class Trace(Plugin):
    def __init__(self, runtime):
        super().__init__()
        self.runtime = runtime

    def will_evm_execute_instruction_callback(self, state, instruction, arguments):
        pc = int(state.platform.current_vm.pc)
        state.context.setdefault("audit_trace", []).append(
            {"pc": pc, "opcode": hex(self.runtime[pc]), "instruction": str(instruction)}
        )


def run_case(label, runtime, calldata, workspace):
    m = ManticoreEVM(workspace_url=str(workspace / label))
    m.register_plugin(Trace(runtime))
    detectors = [DetectInvalid(), DetectIntegerOverflow(), DetectReentrancySimple(), DetectUnusedRetVal()]
    for detector in detectors:
        m.register_detector(detector)
    caller = m.create_account(balance=10**20, name="caller", address=0x1000)
    router = m.create_account(code=runtime, name=label, address=0x2000)
    if calldata is None:
        calldata = m.make_symbolic_buffer(260, name="symbolic_calldata")
    m.transaction(caller=caller, address=router, value=0, data=calldata, gas=10_000_000)
    states = []
    for state in m.all_states:
        tx = state.platform.last_transaction
        findings = []
        for detector in detectors:
            for finding in detector.get_findings(state):
                findings.append({"detector": type(detector).__name__, "finding": str(finding)})
        states.append({
            "id": state.id,
            "result": tx.result if tx else None,
            "return_data": bytes(state.solve_one(tx.return_data)).hex() if tx and tx.return_data is not None else None,
            "trace": state.context.get("audit_trace", []),
            "findings": findings,
        })
    return {"label": label, "states": states, "registered_detectors": [type(d).__name__ for d in detectors]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    args = parser.parse_args()
    args.workspace.mkdir(parents=True, exist_ok=True)
    config.get_group("core").mprocessing = MProcessingType.single
    config.get_group("core").procs = 1
    artifact = json.loads(args.artifact.read_text())
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    settings = artifact["metadata"]["settings"]
    opcodes = {"PUSH0": [], "MCOPY": [], "TLOAD": [], "TSTORE": []}
    new_opcodes = {0x5f: "PUSH0", 0x5e: "MCOPY", 0x5c: "TLOAD", 0x5d: "TSTORE"}
    # Skip PUSH immediates and trailing Solidity CBOR metadata.
    code_end = len(runtime) - int.from_bytes(runtime[-2:], "big") - 2
    pc = 0
    while pc < code_end:
        opcode = runtime[pc]
        if opcode in new_opcodes:
            opcodes[new_opcodes[opcode]].append(pc)
        pc += 1 + (opcode - 0x5f if 0x60 <= opcode <= 0x7f else 0)
    report = {
        "tool": "Manticore Python EVM API",
        "manticore_version": importlib.metadata.version("manticore"),
        "python": platform.python_version(),
        "artifact": str(args.artifact.resolve()),
        "runtime_bytes": len(runtime),
        "runtime_sha256": hashlib.sha256(runtime).hexdigest(),
        "compiler": artifact["metadata"]["compiler"],
        "evm_version": settings["evmVersion"],
        "via_ir": settings.get("viaIR"),
        "new_opcode_inventory": {name: {"count": len(pcs), "first_pcs": pcs[:10]} for name, pcs in opcodes.items()},
        "scope": "Compatibility probe only; no deployment, invariant, or full symbolic security analysis.",
    }
    report["cases"] = [
        run_case("legacy_positive_control", bytes.fromhex("602a60005260206000f3"), b"", args.workspace),
        run_case("ValariRouter_poolCount", runtime, bytes.fromhex("f525cb68"), args.workspace),
        run_case("ValariRouter_symbolic_calldata", runtime, None, args.workspace),
    ]
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
