"""Limited Manticore SMT check of commission arithmetic, NOT contract execution.

This re-expresses the router's private _commission calculation on two symbolic
16-bit fee amounts with exact 32-bit intermediates. It does not execute Solidity,
verify FullMath, model token transfers, or cover arbitrary uint256 fees.
"""
import importlib.metadata
import json
import time

from manticore.core.smtlib import ConstraintSet, Operators, SelectedSolver
from manticore.utils import config


def main():
    config.get_group("smt").timeout = 30
    constraints = ConstraintSet()
    fee0 = Operators.ZEXTEND(constraints.new_bitvec(16, name="fees_first"), 32)
    fee1 = Operators.ZEXTEND(constraints.new_bitvec(16, name="fees_second"), 32)

    def commission(fees, previous_remainder):
        # For this bounded domain, multiplication cannot overflow uint32.
        product = fees * 1000
        fractional = product.urem(10_000) + previous_remainder
        return product.udiv(10_000) + fractional.udiv(10_000), fractional.urem(10_000)

    c0, r0 = commission(fee0, 0)
    c1, r1 = commission(fee1, r0)
    solver = SelectedSolver.instance()
    properties = {
        "first_commission_does_not_exceed_fees": c0.ule(fee0),
        "second_commission_does_not_exceed_fees": c1.ule(fee1),
        "remainder_is_below_denominator": r1.ult(10_000),
        "two_claims_equal_floor_of_total_divided_by_ten": c0 + c1 == (fee0 + fee1).udiv(10),
        "remainder_tracks_cumulative_fraction": r1 == ((fee0 + fee1) * 1000).urem(10_000),
    }
    print(json.dumps({
        "tool": "Manticore SMT API (Z3 backend)",
        "manticore_version": importlib.metadata.version("manticore"),
        "z3_version": importlib.metadata.version("z3-solver"),
        "domain": "Two fee amounts independently in [0,65535], starting remainder 0, uint32 intermediates.",
        "scope": "Re-expressed arithmetic model only; neither EVM execution nor production FullMath implementation verified.",
    }), flush=True)
    for name, prop in properties.items():
        start = time.monotonic()
        try:
            counterexample = solver.can_be_true(constraints, ~prop)
            result = "COUNTEREXAMPLE_EXISTS" if counterexample else "PASS_UNSAT_COUNTEREXAMPLE"
            print(json.dumps({"property": name, "result": result, "seconds": round(time.monotonic() - start, 3)}), flush=True)
        except Exception as error:
            print(json.dumps({"property": name, "result": "INCONCLUSIVE", "error": repr(error), "seconds": round(time.monotonic() - start, 3)}), flush=True)


if __name__ == "__main__":
    main()
