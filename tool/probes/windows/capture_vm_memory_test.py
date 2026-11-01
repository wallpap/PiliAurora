import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("vm_capture", Path(__file__).with_name("capture_vm_memory.py"))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureParsingTest(unittest.TestCase):
    def test_uri_file_log_normalization_and_loopback_boundary(self):
        self.assertEqual(capture.service_uri("VM listening on http://127.0.0.1:1234/fake-auth=/"),
                         "http://127.0.0.1:1234/fake-auth=/")
        self.assertEqual(capture.service_uri("ws://localhost:1234/fake-auth=/ws"),
                         "http://localhost:1234/fake-auth=/")
        with self.assertRaises(ValueError):
            capture.service_uri("http://example.com/token/")

    def test_profile_sorts_live_bytes_and_excludes_object_contents(self):
        rows = capture.allocation_rows({"type": "AllocationProfile", "members": [
            {"class": {"id": "classes/1", "name": "Small"}, "bytesCurrent": 10,
             "instancesCurrent": 2, "valueAsString": "not exported"},
            {"class": {"id": "classes/2", "name": "Large"}, "bytesCurrent": 50,
             "instancesCurrent": 1}]})
        self.assertEqual([row["class"] for row in rows], ["Large", "Small"])
        self.assertNotIn("valueAsString", rows[1])


if __name__ == "__main__":
    unittest.main()
