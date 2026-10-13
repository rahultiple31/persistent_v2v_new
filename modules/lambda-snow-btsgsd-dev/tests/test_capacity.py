import importlib.util
import pathlib
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "check_capacity", pathlib.Path(__file__).parents[1] / "scripts" / "check_capacity.py"
)
capacity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capacity)


class CapacityTest(unittest.TestCase):
    query = {"region": "us-east-1", "account_id": "518902362956", "function_name": "SNOW_btsgsd-dev"}

    def result_for(self, unreserved, concurrency):
        responses = [
            {"Account": self.query["account_id"]},
            {"AccountLimit": {"UnreservedConcurrentExecutions": unreserved}},
            concurrency,
        ]
        with patch.object(capacity, "aws_json", side_effect=responses):
            return capacity.check_capacity(self.query)

    def test_new_function_boundary(self):
        missing = capacity.AwsCliError("An error occurred (ResourceNotFoundException)")
        self.assertEqual(self.result_for(400, missing)["maximum_reservation"], "300")
        self.assertEqual(self.result_for(399, missing)["maximum_reservation"], "299")

    def test_existing_reservation_is_reusable(self):
        result = self.result_for(100, {"ReservedConcurrentExecutions": 300})
        self.assertEqual(result["maximum_reservation"], "300")

    def test_existing_unreserved_function(self):
        self.assertEqual(self.result_for(400, {})["maximum_reservation"], "300")

    def test_access_denied_is_not_treated_as_missing_function(self):
        with self.assertRaises(capacity.AwsCliError):
            self.result_for(400, capacity.AwsCliError("An error occurred (AccessDeniedException)"))

    def test_wrong_account_is_rejected(self):
        with patch.object(capacity, "aws_json", return_value={"Account": "000000000000"}):
            with self.assertRaisesRegex(RuntimeError, "same AWS account"):
                capacity.check_capacity(self.query)


if __name__ == "__main__":
    unittest.main()
