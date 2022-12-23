#!python3
""" map currencies by cmc-id """
import json
import sys


def load_json(file_name):
    """ helper function """
    with open(file_name) as file:
        res = json.load(file)
    return res


def curr_map(source: list, c_map: dict):
    """ return list of mapped currency IDs ("XTVC..." code or None/null if no cmc-id provided or cmc-id not in map)"""
    return [c_map.get(str(i), None) for i in source]


def main():
    """ main routine """
    # load map of cmc-id that exists into currency.json
    c_map = {c["cmc-id"]: c["id"] for c in load_json(sys.argv[1])}
    symbols_file = sys.argv[2]
    symbol_info = load_json(symbols_file)
    mapped = False
    print("currencies: ", len(c_map), "symbols:", len(symbol_info["symbol"]))
    if "currency-cmc-id" in symbol_info and isinstance(symbol_info["currency-cmc-id"], list):
        symbol_info["currency-id"] = curr_map(symbol_info["currency-cmc-id"], c_map)
        mapped = True
    if "base-currency-cmc-id" in symbol_info and isinstance(symbol_info["base-currency-cmc-id"], list):
        symbol_info["base-currency-id"] = curr_map(symbol_info["base-currency-cmc-id"], c_map)
        mapped = True
    if mapped:
        print("currencies are mapped")
        with open(symbols_file, "w") as file:
            json.dump(symbol_info, file, indent=2)


if __name__ == "__main__":
    main()
