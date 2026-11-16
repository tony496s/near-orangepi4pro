import os
import tempfile
import unittest

from near_voice.stt import pick_model_files


class PickModelFilesTest(unittest.TestCase):
    def make(self, d, names):
        for n in names:
            open(os.path.join(d, n), "w").close()

    def test_prefers_int8_files_like_the_e4_model(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, ["encoder.int8.onnx", "encoder.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt",
                          "bpe.model"])
            files = pick_model_files(d)
        self.assertEqual({k: os.path.basename(v) for k, v in files.items()},
                         {"encoder": "encoder.int8.onnx", "decoder": "decoder.onnx", "joiner": "joiner.int8.onnx",
                          "tokens": "tokens.txt"})

    def test_missing_file_is_a_clear_error(self):
        with tempfile.TemporaryDirectory() as d:
            self.make(d, ["encoder.int8.onnx", "decoder.onnx", "tokens.txt"])
            with self.assertRaises(FileNotFoundError) as ctx:
                pick_model_files(d)
        self.assertIn("joiner", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
