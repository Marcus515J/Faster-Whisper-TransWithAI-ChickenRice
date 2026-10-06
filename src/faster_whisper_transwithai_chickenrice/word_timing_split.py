"""Optional word-timestamp based subtitle splitting.

The splitter requests faster-whisper word timestamps only when explicitly
enabled, then converts coarse Whisper segments into subtitle-sized segments.
Word timestamps decide *where* to split, while the final subtitle text is sliced
from the original Whisper segment text so decoded text is never lost.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from difflib import SequenceMatcher
from functools import wraps
from types import SimpleNamespace
from typing import Any


@dataclass(frozen=True)
class WordTimingSplitOptions:
    enabled: bool = False
    max_duration_s: float = 5.0
    pause_threshold_s: float = 0.35
    min_duration_s: float = 0.8
    min_display_duration_s: float = 0.6
    end_hold_s: float = 0.5
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
        min_display_duration_s=max(
            0.0,
            float(value.get("min_display_duration_s", defaults.min_display_duration_s)),
        ),
        end_hold_s=max(0.0, float(value.get("end_hold_s", defaults.end_hold_s))),
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


def _map_compact_boundary(source: str, target: str, source_boundary: int) -> int:
    """Map a character boundary from aligned compact source text to target text."""

    if source_boundary <= 0:
        return 0
    if source_boundary >= len(source):
        return len(target)

    matcher = SequenceMatcher(None, source, target, autojunk=False)
    for _tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if i1 <= source_boundary <= i2:
            if i2 == i1:
                return j2
            ratio = (source_boundary - i1) / (i2 - i1)
            return max(0, min(len(target), round(j1 + ratio * (j2 - j1))))

    return len(target)


def _compact_boundary_to_original_index(text: str, compact_boundary: int) -> int:
    """Convert a compact-text boundary back into an index in the original text."""

    non_space_positions = [index for index, char in enumerate(text) if not char.isspace()]
    if compact_boundary <= 0:
        return 0
    if compact_boundary >= len(non_space_positions):
        return len(text)
    return non_space_positions[compact_boundary]


def _trailing_token(text: str) -> tuple[str, str] | None:
    """Return (prefix, trailing token) when a short whitespace token is present."""

    stripped = text.rstrip()
    split_at = stripped.rfind(" ")
    if split_at < 0:
        return None
    prefix = stripped[:split_at].rstrip()
    token = stripped[split_at + 1 :].strip()
    if not prefix or not token:
        return None
    return prefix, token


def _rebalance_short_text_pieces(pieces: list[str]) -> list[str]:
    """Avoid awkward text boundaries such as ``好 / 舒服`` or ``...地方 / 呢``.

    This changes only which side of an existing time boundary owns a few
    characters; it never removes or duplicates characters.
    """

    result = list(pieces)
    for index in range(1, len(result)):
        current = result[index].strip()
        previous = result[index - 1].strip()
        current_compact = _compact_text(current)
        previous_compact = _compact_text(previous)

        if not current_compact or not previous_compact:
            continue

        trailing = _trailing_token(previous)
        if trailing is not None:
            prefix, token = trailing
            if len(_compact_text(token)) == 1 and len(current_compact) <= 4:
                result[index - 1] = prefix
                result[index] = f"{token}{current}".strip()
                continue

        if len(current_compact) == 1 and len(previous_compact) >= 6:
            move_chars = 2
            compact_seen = 0
            cut_index = len(previous)
            for position in range(len(previous) - 1, -1, -1):
                if previous[position].isspace():
                    continue
                compact_seen += 1
                if compact_seen == move_chars:
                    cut_index = position
                    break

            prefix = previous[:cut_index].rstrip()
            suffix = previous[cut_index:].strip()
            if prefix and suffix:
                result[index - 1] = prefix
                result[index] = f"{suffix}{current}".strip()

    return result


def _slice_original_text_for_groups(segment_text: str, groups: list[list[Any]]) -> list[str] | None:
    """Use timing-word boundaries to slice the original segment text losslessly."""

    if not groups:
        return None

    source = _compact_text("".join(word.word for group in groups for word in group))
    target = _compact_text(segment_text)
    if not source or not target:
        return None

    matcher = SequenceMatcher(None, source, target, autojunk=False)
    if matcher.ratio() < 0.60:
        return None

    source_boundaries: list[int] = []
    consumed = 0
    for group in groups[:-1]:
        consumed += len(_compact_text("".join(word.word for word in group)))
        source_boundaries.append(consumed)

    compact_target_boundaries = [
        _map_compact_boundary(source, target, boundary) for boundary in source_boundaries
    ]
    original_boundaries = [
        _compact_boundary_to_original_index(segment_text, boundary) for boundary in compact_target_boundaries
    ]

    previous = 0
    for boundary in original_boundaries:
        if boundary <= previous or boundary >= len(segment_text):
            return None
        previous = boundary

    pieces: list[str] = []
    start = 0
    for boundary in original_boundaries:
        pieces.append(segment_text[start:boundary].strip())
        start = boundary
    pieces.append(segment_text[start:].strip())

    if len(pieces) != len(groups) or any(not piece for piece in pieces):
        return None

    pieces = _rebalance_short_text_pieces(pieces)

    if any(not piece for piece in pieces):
        return None
    if _compact_text("".join(pieces)) != _compact_text(segment_text):
        return None

    return pieces


def split_segment_by_words(segment: Any, options: WordTimingSplitOptions) -> list[Any]:
    """Split one faster-whisper segment on word timing boundaries."""

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

    if len(groups) <= 1:
        if groups:
            return [
                SubtitleSegment(
                    start=groups[0][0].start,
                    end=groups[0][-1].end,
                    text=str(getattr(segment, "text", "")).strip(),
                )
            ]
        return [segment]

    pieces = _slice_original_text_for_groups(str(getattr(segment, "text", "")), groups)
    if pieces is None:
        return [segment]

    return [
        SubtitleSegment(start=group[0].start, end=group[-1].end, text=text)
        for group, text in zip(groups, pieces, strict=True)
    ]


def _apply_display_timing(
    segments: list[Any], options: WordTimingSplitOptions
) -> list[SubtitleSegment]:
    """Keep subtitle starts precise while avoiding premature disappearance.

    Word-level timestamps are reliable for starts but their final word end can be
    slightly early. Each subtitle therefore gets a small configurable tail hold.
    The hold is always clamped to the next subtitle start, so it cannot create
    overlaps or turn into a long trailing-silence display.
    """

    result: list[SubtitleSegment] = []
    for index, segment in enumerate(segments):
        start = float(segment.start)
        end = float(segment.end)
        text = str(segment.text).strip()

        desired_end = end
        if options.end_hold_s > 0:
            desired_end = max(desired_end, end + options.end_hold_s)
        if options.min_display_duration_s > 0:
            desired_end = max(desired_end, start + options.min_display_duration_s)

        if index + 1 < len(segments):
            next_start = float(segments[index + 1].start)
            desired_end = min(desired_end, next_start)

        end = max(end, desired_end)
        result.append(SubtitleSegment(start=start, end=end, text=text))

    return result


def split_segments_by_words(segments: Iterable[Any], options: WordTimingSplitOptions):
    split_segments: list[Any] = []
    for segment in segments:
        split_segments.extend(split_segment_by_words(segment, options))

    yield from _apply_display_timing(split_segments, options)


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
