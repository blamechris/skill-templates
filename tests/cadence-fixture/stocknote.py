"""A small inventory utility; standard-library Python only."""
import argparse
import json
import sys


def canonical_label(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("labels must be nonempty strings")
    return " ".join(value.split()).casefold()


def clean_records(records):
    """Validate input and return canonical records without mutating the caller."""
    result = []
    for record in records:
        quantity = record["quantity"]
        if type(quantity) is not int or quantity < 0:
            raise ValueError("quantity must be a nonnegative integer")
        result.append({"name": canonical_label(record["name"]),
                       "category": canonical_label(record["category"]),
                       "quantity": quantity})
    return result


def count(records):
    return sum(record["quantity"] for record in clean_records(records))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["count"])
    parser.parse_args()
    print(json.dumps(count(json.load(sys.stdin)), sort_keys=True))


if __name__ == "__main__":
    main()
