import json
import unittest

from near_voice import protocol as p


class DecodeCommandTest(unittest.TestCase):
    def test_listen(self):
        self.assertEqual(p.decode_command('{"cmd":"listen","id":"a1"}'), p.Listen("a1"))

    def test_listen_from_bytes_with_newline(self):
        self.assertEqual(p.decode_command(b'{"cmd":"listen","id":"a1"}\n'), p.Listen("a1"))

    def test_cancel(self):
        self.assertEqual(p.decode_command('{"cmd":"cancel"}'), p.Cancel())

    def test_finish(self):
        self.assertEqual(p.decode_command('{"cmd":"finish"}'), p.Finish())

    def test_chime(self):
        self.assertEqual(p.decode_command('{"cmd":"chime","name":"soft"}'), p.Chime("soft"))

    def test_wake_on_and_off(self):
        self.assertEqual(p.decode_command('{"cmd":"wake","on":true}'), p.Wake(True))
        self.assertEqual(p.decode_command('{"cmd":"wake","on":false}'), p.Wake(False))

    def test_unknown_command_is_ignored_for_forward_compatibility(self):
        self.assertIsNone(p.decode_command('{"cmd":"say","id":"x","text":"xin chào"}'))

    def test_malformed_lines_raise(self):
        for line in ['not json', '[1,2]', '{"id":"a"}', '{"cmd":"listen"}', '{"cmd":"listen","id":""}',
                     '{"cmd":"listen","id":5}', '{"cmd":"chime"}', '{"cmd":7}', b'\xff\xfe',
                     '{"cmd":"wake"}', '{"cmd":"wake","on":1}', '{"cmd":"wake","on":"true"}']:
            with self.subTest(line=line):
                with self.assertRaises(p.ProtocolError):
                    p.decode_command(line)


class EncodeEventTest(unittest.TestCase):
    def decode(self, data: bytes) -> dict:
        self.assertTrue(data.endswith(b"\n"))
        self.assertEqual(data.count(b"\n"), 1)
        return json.loads(data)

    def test_events_match_the_spec(self):
        self.assertEqual(self.decode(p.ready("zipformer-vi", "zipformer")),
                         {"ev": "ready", "model": "zipformer-vi", "stt": "zipformer", "tts": False, "wake": "off"})
        self.assertEqual(self.decode(p.listening("a1")), {"ev": "listening", "id": "a1"})
        self.assertEqual(self.decode(p.level(-31.54)), {"ev": "level", "db": -31.5})
        self.assertEqual(self.decode(p.processing("a1")), {"ev": "processing", "id": "a1"})
        self.assertEqual(self.decode(p.final("a1", "hẹn giờ", 1800, 170, "zipformer")),
                         {"ev": "final", "id": "a1", "text": "hẹn giờ", "audio_ms": 1800, "stt_ms": 170,
                          "engine": "zipformer"})
        self.assertEqual(self.decode(p.timeout("a1", p.NO_SPEECH)), {"ev": "timeout", "id": "a1", "reason": "no_speech"})
        self.assertEqual(self.decode(p.error("stt: boom")), {"ev": "error", "msg": "stt: boom"})
        self.assertEqual(self.decode(p.wake("HEY_NEAR")), {"ev": "wake", "keyword": "HEY_NEAR"})

    def test_vietnamese_text_is_utf8_not_escaped(self):
        data = p.final("a1", "ĐẶT HẸN GIỜ", 1, 1, "zipformer")
        self.assertIn("ĐẶT HẸN GIỜ".encode("utf-8"), data)

    def test_newline_in_text_does_not_break_the_line_framing(self):
        data = p.final("a1", "một\nhai", 1, 1, "zipformer")
        self.assertEqual(self.decode(data)["text"], "một\nhai")


if __name__ == "__main__":
    unittest.main()
