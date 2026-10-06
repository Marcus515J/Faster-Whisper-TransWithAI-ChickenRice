import types
import unittest
from unittest.mock import patch

from faster_whisper_transwithai_chickenrice import subtitle_refine_patch as refine
from faster_whisper_transwithai_chickenrice import word_timing_split as wts


def make_word(start, end, text, probability=0.9):
    return types.SimpleNamespace(
        start=start,
        end=end,
        word=text,
        probability=probability,
    )


def make_segment(
    start,
    end,
    text,
    *,
    avg_logprob=-0.2,
    compression_ratio=1.2,
    no_speech_prob=0.05,
    words=None,
):
    return types.SimpleNamespace(
        start=start,
        end=end,
        text=text,
        avg_logprob=avg_logprob,
        compression_ratio=compression_ratio,
        no_speech_prob=no_speech_prob,
        words=words,
    )


class SubtitleRefinePatchTests(unittest.TestCase):
    def test_long_vad_span_does_not_force_max_extension(self):
        options = wts.SubtitleRefineOptions(
            enabled=True,
            align_end_to_vad=True,
            max_end_extension_s=0.8,
        )
        result = refine.align_segment_ends_to_vad(
            [make_segment(1.0, 2.0, "test")],
            [0.0, 10.0],
            options,
        )
        self.assertAlmostEqual(result[0].end, 2.0)

    def test_near_vad_tail_extends_to_exact_tail(self):
        options = wts.SubtitleRefineOptions(
            enabled=True,
            align_end_to_vad=True,
            max_end_extension_s=0.8,
        )
        result = refine.align_segment_ends_to_vad(
            [make_segment(1.0, 2.0, "test")],
            [0.0, 2.35],
            options,
        )
        self.assertAlmostEqual(result[0].end, 2.35)

    def test_local_word_burst_flags_coarse_segment(self):
        options = wts.SubtitleRefineOptions(enabled=True, suspicious_chars_per_second=8.0)
        segment = make_segment(
            0.0,
            10.0,
            "前半ありがとうございました後半",
            words=[
                make_word(0.0, 3.0, "前半"),
                make_word(6.0, 6.8, "ありがとうございました"),
                make_word(8.0, 10.0, "後半"),
            ],
        )
        self.assertTrue(refine.is_suspicious_segment(segment, options))

    def test_low_word_probability_flags_segment(self):
        options = wts.SubtitleRefineOptions(enabled=True)
        segment = make_segment(
            0.0,
            2.0,
            "カステラ",
            words=[
                make_word(0.2, 0.9, "カス", 0.35),
                make_word(1.0, 1.7, "テラ", 0.40),
            ],
        )
        self.assertTrue(refine.is_suspicious_segment(segment, options))

    def test_retry_budget_selects_worst_candidate_globally(self):
        options = wts.SubtitleRefineOptions(
            enabled=True,
            retry_suspicious=True,
            retry_max_segments=1,
        )
        segments = [
            make_segment(
                0.0,
                1.0,
                "early",
                avg_logprob=-0.51,
                words=[make_word(0.0, 1.0, "early", 0.49)],
            ),
            make_segment(
                2.0,
                3.0,
                "late",
                avg_logprob=-0.70,
                words=[make_word(2.0, 3.0, "late", 0.20)],
            ),
        ]

        def fake_retry(_owner, _original, _audio, segment, _kwargs, _options):
            return [
                make_segment(
                    segment.start,
                    segment.end,
                    "fixed",
                    avg_logprob=-0.05,
                    words=[make_word(segment.start, segment.end, "fixed", 0.95)],
                )
            ]

        with patch.object(wts, "_retry_segment", side_effect=fake_retry):
            result = refine.refine_suspicious_segments(
                object(),
                object(),
                [0.0] * 100,
                segments,
                {},
                options,
            )

        self.assertEqual([item.text for item in result], ["early", "fixed"])


if __name__ == "__main__":
    unittest.main()
