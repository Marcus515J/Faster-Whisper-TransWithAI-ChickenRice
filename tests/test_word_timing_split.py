import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from faster_whisper_transwithai_chickenrice.word_timing_split import (
    WordTimingSplitOptions,
    parse_word_timing_split_options,
    split_segment_by_words,
)


def make_word(start: float, end: float, text: str):
    return types.SimpleNamespace(start=start, end=end, word=text)


def make_segment(start: float, end: float, text: str, words=None):
    return types.SimpleNamespace(start=start, end=end, text=text, words=words)


class WordTimingSplitTests(unittest.TestCase):
    def test_disabled_returns_original_segment(self) -> None:
        segment = make_segment(0.0, 6.0, "A B", [make_word(0.0, 1.0, "A"), make_word(5.0, 6.0, " B")])

        result = split_segment_by_words(segment, WordTimingSplitOptions(enabled=False))

        self.assertEqual(result, [segment])

    def test_missing_word_timestamps_returns_original_segment(self) -> None:
        segment = make_segment(0.0, 6.0, "A B", None)

        result = split_segment_by_words(segment, WordTimingSplitOptions(enabled=True))

        self.assertEqual(result, [segment])

    def test_mismatched_word_text_returns_original_segment(self) -> None:
        segment = make_segment(
            0.0,
            3.0,
            "完整文本",
            [make_word(0.0, 1.0, "完整"), make_word(1.1, 2.0, "文")],
        )

        result = split_segment_by_words(segment, WordTimingSplitOptions(enabled=True))

        self.assertEqual(result, [segment])

    def test_splits_on_silence_without_losing_text(self) -> None:
        segment = make_segment(
            0.0,
            4.0,
            "你好世界",
            [
                make_word(0.0, 0.8, "你好"),
                make_word(2.2, 3.0, "世界"),
            ],
        )
        options = WordTimingSplitOptions(
            enabled=True,
            max_duration_s=5.0,
            pause_threshold_s=0.35,
            min_duration_s=0.8,
            split_on_punctuation=False,
        )

        result = split_segment_by_words(segment, options)

        self.assertEqual(len(result), 2)
        self.assertEqual(result[0].text, "你好")
        self.assertEqual(result[1].text, "世界")
        self.assertEqual("".join(item.text for item in result), "你好世界")

    def test_splits_at_word_boundary_when_max_duration_is_exceeded(self) -> None:
        segment = make_segment(
            0.0,
            5.0,
            "ABCD",
            [
                make_word(0.0, 0.9, "A"),
                make_word(1.0, 1.9, "B"),
                make_word(2.0, 2.9, "C"),
                make_word(3.0, 3.9, "D"),
            ],
        )
        options = WordTimingSplitOptions(
            enabled=True,
            max_duration_s=2.0,
            pause_threshold_s=10.0,
            min_duration_s=0.0,
            split_on_punctuation=False,
        )

        result = split_segment_by_words(segment, options)

        self.assertEqual([item.text for item in result], ["AB", "CD"])
        self.assertTrue(all((item.end - item.start) <= 2.0 for item in result))

    def test_merges_short_final_tail_back_within_soft_extension(self) -> None:
        segment = make_segment(
            0.0,
            5.3,
            "ABCDE",
            [
                make_word(0.0, 1.0, "A"),
                make_word(1.0, 2.0, "B"),
                make_word(2.0, 3.0, "C"),
                make_word(3.0, 4.94, "D"),
                make_word(4.94, 5.28, "E"),
            ],
        )
        options = WordTimingSplitOptions(
            enabled=True,
            max_duration_s=5.0,
            pause_threshold_s=10.0,
            min_duration_s=0.8,
            split_on_punctuation=False,
        )

        result = split_segment_by_words(segment, options)

        self.assertEqual([item.text for item in result], ["ABCDE"])
        self.assertAlmostEqual(result[0].end - result[0].start, 5.28)

    def test_splits_on_punctuation_after_minimum_duration(self) -> None:
        segment = make_segment(
            0.0,
            4.0,
            "第一句。第二句",
            [
                make_word(0.0, 0.6, "第一"),
                make_word(0.6, 1.2, "句。"),
                make_word(1.3, 2.0, "第二"),
                make_word(2.0, 2.8, "句"),
            ],
        )
        options = WordTimingSplitOptions(enabled=True, min_duration_s=0.8)

        result = split_segment_by_words(segment, options)

        self.assertEqual([item.text for item in result], ["第一句。", "第二句"])

    def test_parses_config_dictionary(self) -> None:
        options = parse_word_timing_split_options(
            {
                "enabled": True,
                "max_duration_s": 4.5,
                "pause_threshold_s": 0.4,
                "min_duration_s": 1.0,
                "split_on_punctuation": False,
            }
        )

        self.assertTrue(options.enabled)
        self.assertEqual(options.max_duration_s, 4.5)
        self.assertEqual(options.pause_threshold_s, 0.4)
        self.assertEqual(options.min_duration_s, 1.0)
        self.assertFalse(options.split_on_punctuation)


if __name__ == "__main__":
    unittest.main()
