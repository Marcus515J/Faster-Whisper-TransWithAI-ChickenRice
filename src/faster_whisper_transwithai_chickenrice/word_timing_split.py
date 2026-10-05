"""Optional word-timestamp based subtitle splitting.

This module patches faster-whisper's public transcribe methods at import time.
The patch is inert unless ``word_timing_split`` is present and enabled in the
transcription kwargs.  When enabled it requests word timestamps and converts a
coarse Whisper segment into smaller subtitle-sized segments without discarding
text.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import wraps
from types import SimpleNamespace
from typing import Any, Iterable


@dataclass(frozen=True)
class WordTimingSplitOptions:
    enabled: bool = False
    max_duration_s: float = 5.0
    pause_threshold_s: float = 0.35
    min_duration_s: float = 0.8
    split_on_punctuation: bool = True
    punctuation: str = "。！？!?"


@dataclass(frozen=True)
class SubtitleSegment:
    start: float
    end: float
    text: str


def _coerce_bool(value: Any, *, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off"}:
            return False
    return default


def parse_word_timing_split_options(value: Any) -> WordTimingSplitOptions:
    defaults = WordTimingSplitOptions()

    if value is None:
        return defaults
    if isinstance(value, bool):
        return WordTimingSplitOptions(enabled=value)
    if not isinstance(value, dict):
        return defaults

    return WordTimingSplitOptions(
        enabled=_coerce_bool(value.get("enabled"), default=True),
        max_duration_s=max(0.5, float(value.get("max_duration_s", defaults.max_duration_s))),
        pause_threshold_s=max(0.0, float(value.get("pause_threshold_s", defaults.pause_threshold_s))),
        min_duration_s=max(0.0, float(value.get("min_duration_s", defaults.min_duration_s))),
        split_on_punctuation=_coerce_bool(
            value.get("split_on_punctuation"), default=defaults.split_on_punctuation
        ),
        punctuation=str(value.get("punctuation", defaults.punctuation)),
    )


def _normalize_word(word: Any, segment_start: float, segment_end: float):
    start = getattr(word, "start", None)
    end = getattr(word, "end", None)
    text = getattr(word, "word", "")

    if start is None or end is None or not str(text):
        return None

    start = max(float(segment_start), float(start))
    end = min(float(segment_end), float(end))
    if end <= start:
        return None

    return SimpleNamespace(start=start, end=end, word=str(text))


def split_segment_by_words(segment: Any, options: WordTimingSplitOptions) -> list[Any]:
    """Split one faster-whisper segment on word timing boundaries.

    The original segment is returned unchanged when word timestamps are absent.
    Text is never truncated: each emitted subtitle gets the exact concatenation
    of the word strings assigned to that subtitle.
    """

    if not options.enabled:
        return [segment]

    raw_words = getattr(segment, "words", None) or []
    words = [
        normalized
        for normalized in (
            _normalize_word(word, float(segment.start), float(segment.end)) for word in raw_words
        )
        if normalized is not None
    ]
    if not words:
        return [segment]

    result: list[SubtitleSegment] = []
    current: list[Any] = []
    previous = None

    def flush() -> None:
        nonlocal current
        if not current:
            return
        text = "".join(word.word for word in current).strip()
        if text:
            result.append(SubtitleSegment(start=current[0].start, end=current[-1].end, text=text))
        current = []

    for word in words:
        if current and previous is not None:
            gap_s = max(0.0, word.start - previous.end)
            current_duration_s = max(0.0, previous.end - current[0].start)
            duration_if_added_s = max(0.0, word.end - current[0].start)

            split_for_pause = (
                options.pause_threshold_s > 0
                and gap_s >= options.pause_threshold_s
                and current_duration_s >= options.min_duration_s
            )
            split_for_duration = duration_if_added_s > options.max_duration_s and current_duration_s > 0
            if split_for_pause or split_for_duration:
                flush()

        current.append(word)
        previous = word

        current_duration_s = max(0.0, current[-1].end - current[0].start)
        ends_with_punctuation = bool(options.punctuation) and current[-1].word.rstrip().endswith(
            tuple(options.punctuation)
        )
        if (
            options.split_on_punctuation
            and ends_with_punctuation
            and current_duration_s >= options.min_duration_s
        ):
            flush()
            previous = None

    flush()
    return result or [segment]


def split_segments_by_words(segments: Iterable[Any], options: WordTimingSplitOptions):
    for segment in segments:
        yield from split_segment_by_words(segment, options)


def _patch_transcribe_class(cls: Any) -> bool:
    original = getattr(cls, "transcribe", None)
    if original is None or getattr(original, "_chickenrice_word_timing_split", False):
        return False

    @wraps(original)
    def patched(self, *args, **kwargs):
        raw_options = kwargs.pop("word_timing_split", None)
        options = parse_word_timing_split_options(raw_options)
        if not options.enabled:
            return original(self, *args, **kwargs)

        # Ask faster-whisper to retain word-level alignment.  The app's normal
        # generation path will consume only start/end/text from our split
        # segments, so no other code needs to understand Word objects.
        kwargs["word_timestamps"] = True
        segments, info = original(self, *args, **kwargs)
        return split_segments_by_words(segments, options), info

    patched._chickenrice_word_timing_split = True
    cls.transcribe = patched
    return True


def install_word_timing_split_patch() -> bool:
    """Patch standard and batched faster-whisper pipelines when available."""

    try:
        from faster_whisper import BatchedInferencePipeline, WhisperModel
    except Exception:
        return False

    changed = False
    changed = _patch_transcribe_class(WhisperModel) or changed
    changed = _patch_transcribe_class(BatchedInferencePipeline) or changed
    return changed
