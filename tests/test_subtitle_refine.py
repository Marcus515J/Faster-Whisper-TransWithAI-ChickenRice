import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from faster_whisper_transwithai_chickenrice.word_timing_split import (
    SubtitleRefineOptions,
    align_segment_ends_to_vad,
    is_suspicious_segment,
    parse_subtitle_refine_options,
    refine_suspicious_segments,
)


def make_segment(
    start: float,
    end: float,
    text: str,
    *,
    avg_logprob: float | None = None,
    compression_ratio: float | None = None,
    no_speech_prob: float | None = None,
):
    return types.SimpleNamespace(
        start=start,
        end=end,
        text=text,
        avg_logprob=avg_logprob,
        compression_ratio=compression_ratio,
        no_speech_prob=no_speech_prob,
        words=None,
    )


class SubtitleRefineTests(unittest.TestCase):
    def test_parse_refine_options(self) -> None:
        options = parse_subtitle_refine_options(
            {
                "enabled": True,
                "retry_max_segments": 10,
                "retry_beam_size": 4,
                "retry_temperatures": [0.0, 0.3],
                "max_end_extension_s": 0.7,
            }
        )

        self.assertTrue(options.enabled)
        self.assertEqual(options.retry_max_segments, 10)
        self.assertEqual(options.retry_beam_size, 4)
        self.assertEqual(options.retry_temperatures, (0.0, 0.3))
        self.assertEqual(options.max_end_extension_s, 0.7)

    def test_low_logprob_is_suspicious(self) -> None:
        segment = make_segment(0.0, 1.0, "テスト", avg_logprob=-0.9)

        self.assertTrue(is_suspicious_segment(segment, SubtitleRefineOptions(enabled=True)))

    def test_impossible_text_rate_is_suspicious(self) -> None:
        segment = make_segment(0.0, 0.6, "ありがとうございました")

        self.assertTrue(is_suspicious_segment(segment, SubtitleRefineOptions(enabled=True)))

    def test_vad_alignment_uses_real_span_end(self) -> None:
        segments = [
            make_segment(0.0, 1.0, "第一"),
            make_segment(2.0, 2.5, "第二"),
        ]
        options = SubtitleRefineOptions(enabled=True, max_end_extension_s=0.8)

        result = align_segment_ends_to_vad(segments, [0.0, 1.45, 2.0, 2.6], options)

        self.assertAlmostEqual(result[0].end, 1.45)
        self.assertAlmostEqual(result[1].end, 2.6)

    def test_vad_alignment_never_overlaps_next_subtitle(self) -> None:
        segments = [
            make_segment(0.0, 1.0, "第一"),
            make_segment(1.2, 2.0, "第二"),
        ]
        options = SubtitleRefineOptions(enabled=True, max_end_extension_s=0.8)

        result = align_segment_ends_to_vad(segments, [0.0, 1.6], options)

        self.assertAlmostEqual(result[0].end, 1.2)
        self.assertLessEqual(result[0].end, result[1].start)

    def test_empty_retry_drops_only_strong_non_speech(self) -> None:
        segment = make_segment(
            1.0,
            1.6,
            "ありがとうございました",
            avg_logprob=-0.9,
            no_speech_prob=0.9,
        )
        owner = types.SimpleNamespace(feature_extractor=types.SimpleNamespace(sampling_rate=10))
        audio = [0.0] * 100

        def fake_original(_owner, _audio, **_kwargs):
            return iter(()), types.SimpleNamespace()

        result = refine_suspicious_segments(
            owner,
            fake_original,
            audio,
            [segment],
            {"task": "transcribe"},
            SubtitleRefineOptions(enabled=True),
        )

        self.assertEqual(result, [])

    def test_good_retry_replaces_suspicious_segment(self) -> None:
        segment = make_segment(
            1.0,
            2.0,
            "怪しい文章です",
            avg_logprob=-1.1,
            no_speech_prob=0.3,
        )
        owner = types.SimpleNamespace(feature_extractor=types.SimpleNamespace(sampling_rate=10))
        audio = [0.0] * 100

        retry_segment = make_segment(
            0.25,
            1.0,
            "正しい",
            avg_logprob=-0.2,
            compression_ratio=1.0,
            no_speech_prob=0.05,
        )

        def fake_original(_owner, _audio, **_kwargs):
            return iter((retry_segment,)), types.SimpleNamespace()

        result = refine_suspicious_segments(
            owner,
            fake_original,
            audio,
            [segment],
            {"task": "transcribe"},
            SubtitleRefineOptions(enabled=True),
        )

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].text, "正しい")
        self.assertAlmostEqual(result[0].start, 1.0)


if __name__ == "__main__":
    unittest.main()
