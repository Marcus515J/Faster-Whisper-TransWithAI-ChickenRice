"""Optional word-timestamp based subtitle splitting.

The splitter requests faster-whisper word timestamps only when explicitly
enabled, then converts coarse Whisper segments into subtitle-sized segments.
It never truncates text to satisfy a duration limit.
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


def _compact_text(text: Any) -> str:
    return "".join(str(text or "").split())


def _normalize_word(word: Any, segment_start: float, segment_end: float):
    start = getattr(word, "start", None)
    end = getattr(word, "end", None)
    text = str(getattr(word, "word", ""))

    if start is None or end is None or not text.strip():
        return None

    start = max(float(segment_start), float(start))
    end = min(float(segment_end), float(end))
    if end <= start:
        return None

    return SimpleNamespace(start=start, end=end, word=text)


def _group_duration(words: list[Any]) -> float:
    if not words:
        return 0.0
    return max(0.0, words[-1].end - words[0].start)


def split_segment_by_words(segment: Any, options: WordTimingSplitOptions) -> list[Any]:
    """Split one faster-whisper segment on word timing boundaries.

    Safety rules:
    - If word timestamps are absent, keep the original segment.
    - If the concatenated word text does not match the original segment text,
      keep the original segment instead of risking text loss.
    - ``max_duration_s`` is a target, not a destructive hard cap. A short final
      fragment may be merged back into the previous subtitle when the combined
      duration is no more than ``max_duration_s + min_duration_s``.
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

    # Word alignment must account for the complete decoded segment text. If it
    # does not, refuse to split rather than silently dropping text.
    if _compact_text("".join(word.word for word in words)) != _compact_text(getattr(segment, "text", "")):
        return [segment]

    groups: list[list[Any]] = []
    current: list[Any] = []
    previous = None

    def flush() -> None:
        nonlocal current
        if current:
            groups.append(current)
            current = []

    for word in words:
        if current and previous is not None:
            gap_s = max(0.0, word.start - previous.end)
            current_duration_s = _group_duration(current)
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

        current_duration_s = _group_duration(current)
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

    # Avoid pathological tails such as a 4.94 s subtitle followed by a 0.34 s
    # one-word fragment merely because the target duration was crossed. Allow a
    # small extension (up to min_duration_s) and merge the final tail back.
    if len(groups) >= 2 and options.min_duration_s > 0:
        tail = groups[-1]
        previous_group = groups[-2]
        combined_duration_s = tail[-1].end - previous_group[0].start
        if (
            _group_duration(tail) < options.min_duration_s
            and combined_duration_s <= options.max_duration_s + options.min_duration_s
        ):
            previous_group.extend(tail)
            groups.pop()

    result: list[SubtitleSegment] = []
    for group in groups:
        text = "".join(word.word for word in group).strip()
        if text:
            result.append(SubtitleSegment(start=group[0].start, end=group[-1].end, text=text))

    if not result:
        return [segment]

    # Final preservation check across all emitted subtitles.
    if _compact_text("".join(item.text for item in result)) != _compact_text(getattr(segment, "text", "")):
        return [segment]

    return result


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
