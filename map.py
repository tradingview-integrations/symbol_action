#!python3
""" map currencies by cmc-id """

import json
import sys


def load_json(file_name):
    """ helper function """
    with open(file_name) as file:
        res = json.load(file)
    return res


def curr_map(source, c_map):
    """ map currencies """
    return [c_map.get(i, F"ERROR mapping for cmc-id: {i}") for i in source]


def main():
    """ main routine """
    c_map = {c["cmc-id"]: c["id"] for c in load_json("currency.json")}
    group = sys.argv[1]
    symbol_info = load_json(group)
    mapped = False
    if "currency-cmc-id" in symbol_info:
        symbol_info["currency"] = curr_map(symbol_info["currency-cmc-id"], c_map)
        del symbol_info["currency-cmc-id"]
        mapped = True
    if "base-currency-cmc-id" in symbol_info:
        symbol_info["base-currency"] = curr_map(symbol_info["base-currency-cmc-id"], c_map)
        del symbol_info["base-currency-cmc-id"]
        mapped = True
    if mapped:
        with open(group, "w") as file:
            json.dump(file, symbol_info, indent=2)
