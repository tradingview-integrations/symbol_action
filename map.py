#!python3

import json
import sys

def load_json(fime_name):
  with open(file_name) as f:
    res = json.load(f)
  return res

def main():
  c_map = {c["cmc-id"]: c["id"] for c in load_json("currency.json")
  group = sys.argv[1]
  symbol_info = load_json(group)
  symbol_info["currency"] = [c_map[i] for i in symbol_info["currency-cmc-id"]]
  symbol_info["base-currency"] = [c_map[i] for i in symbol_info["base-currency-cmc-id"]]
  del symbol_info["currency-cmc-id"]
  del symbol_info["base-currency-cmc-id"]
  with open(group, "w") as f:
     json.dump(f, symbol_info)
     
