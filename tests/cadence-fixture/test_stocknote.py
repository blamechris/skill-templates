import unittest
from stocknote import canonical_label, clean_records, count


class BaselineTests(unittest.TestCase):
    def test_canonical_label_collapses_and_casefolds(self):
        self.assertEqual(canonical_label(" STRAẞE   Pen "), "strasse pen")

    def test_records_are_copied(self):
        original = [{"name": " Pen ", "category": " Office", "quantity": 3}]
        self.assertEqual(clean_records(original)[0]["name"], "pen")
        self.assertEqual(original[0]["name"], " Pen ")
        self.assertEqual(count(original), 3)

    def test_invalid_quantity(self):
        for value in (-1, True, "3", 1.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                count([{"name": "Pen", "category": "Office", "quantity": value}])


if __name__ == "__main__":
    unittest.main()
