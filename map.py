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
    # for i in source:
    #     curr_id = c_map.get(i, None)
    #     # if curr_id is None:
    #     #     # what to do here ?
    #     res.append(curr_id)
    # return res


def main():
    """ main routine """
    c_map = {c["cmc-id"]: c["id"] for c in load_json("currency.json")}
    group = sys.argv[1]
    symbol_info = load_json(group)
    symbol_info["currency"] = curr_map(symbol_info["currency-cmc-id"], c_map)
    symbol_info["base-currency"] = curr_map(symbol_info["base-currency-cmc-id"], c_map)
    del symbol_info["currency-cmc-id"]
    del symbol_info["base-currency-cmc-id"]
    with open(group, "w") as file:
        json.dump(file, symbol_info)
