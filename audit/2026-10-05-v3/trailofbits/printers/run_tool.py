#!/usr/bin/env python3
"""Run a slither-* tool (slither-check-erc, slither-check-upgradeability) with the
same SafeCast library-scope fix as audit/2026-10-05/slither/run_with_scope_fix.py.
Usage: python run_tool.py <module> <tool args...>, e.g. module =
slither.tools.erc_conformance.__main__ or slither.tools.upgradeability.__main__
"""
import importlib
import sys

from slither.core.solidity_types.user_defined_type import UserDefinedType
from slither.solc_parsing.declarations import contract
from slither.solc_parsing.solidity_types.type_parsing import _add_type_references

upstream_parse_type = contract.parse_type


def parse_type_with_library_id(ast_node, caller_context):
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


contract.parse_type = parse_type_with_library_id
module = sys.argv[1]
sys.argv = [module] + sys.argv[2:]
importlib.import_module(module).main()
