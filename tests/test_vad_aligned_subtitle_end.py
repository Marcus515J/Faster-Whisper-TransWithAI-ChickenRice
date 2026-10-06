import types

from faster_whisper_transwithai_chickenrice.word_timing_split import (
    WordTimingSplitOptions,
    split_segments_by_words,
)


def make_word(start: float, end: float, text: str):
    return types.SimpleNamespace(start=start, end=end, word=text)


def make_segment(start: float, end: float, text: str):
    return types.SimpleNamespace(
        start=start,
        end=end,
        text=text,
        words=[make_word(start, end, text)],
    )


def test_final_subtitle_extends_to_vad_speech_end() -> None:
    segments = [make_segment(0.0, 2.0, "第一句")]
    options = WordTimingSplitOptions(enabled=True, end_hold_s=1.0)

    result = list(split_segments_by_words(segments, options, [(0.0, 3.4)]))

    assert result[0].start == 0.0
    assert result[0].end == 3.4


def test_continuous_speech_hands_off_at_next_subtitle_start() -> None:
    segments = [
        make_segment(0.0, 2.0, "第一句"),
        make_segment(2.5, 3.0, "第二句"),
    ]
    options = WordTimingSplitOptions(enabled=True, end_hold_s=1.0)

    result = list(split_segments_by_words(segments, options, [(0.0, 3.6)]))

    assert result[0].end == 2.5
    assert result[1].end == 3.6


def test_vad_end_does_not_cross_next_subtitle() -> None:
    segments = [
        make_segment(0.0, 2.0, "第一句"),
        make_segment(2.2, 3.0, "第二句"),
    ]
    options = WordTimingSplitOptions(enabled=True, end_hold_s=1.0)

    result = list(split_segments_by_words(segments, options, [(0.0, 4.0)]))

    assert result[0].end == 2.2
    assert result[0].end <= result[1].start


def test_fixed_hold_remains_fallback_without_vad_span() -> None:
    segments = [make_segment(0.0, 2.0, "第一句")]
    options = WordTimingSplitOptions(enabled=True, end_hold_s=1.0)

    result = list(split_segments_by_words(segments, options, []))

    assert result[0].end == 3.0
