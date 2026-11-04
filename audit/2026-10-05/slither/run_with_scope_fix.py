#!/usr/bin/env python3
"""Slither 0.11.6 compatibility shim; no Solidity sources or ASTs are modified.

The upstream parser selects a library by its textual name. This contract imports
OpenZeppelin SafeCast and transitively Uniswap SafeCast, so the wrong declaration
can be selected for `using SafeCast for uint256`. Use solc's unambiguous AST
referencedDeclaration for library IdentifierPath nodes, and otherwise retain the
upstream behavior. --disallow-partial makes any remaining IR error fatal.
"""

import sys

from slither.__main__ import main
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
                print(
                    "SLITHER LIBRARY-SCOPE FIX: "
                    f"{ast_node['name']} -> {declaration.source_mapping}; "
                    f"solc referencedDeclaration={reference}; "
                    f"upstream selected {result.type.source_mapping}",
                    file=sys.stderr,
                )
                replacement = UserDefinedType(declaration)
                _add_type_references(
                    replacement, ast_node["src"], caller_context.compilation_unit
                )
                return replacement
    return result


contract.parse_type = parse_type_with_library_id
main()
