"""Optional word-timestamp based subtitle splitting and conservative ASR refinement.

The splitter requests faster-whisper word timestamps only when explicitly
enabled, then converts coarse Whisper segments into subtitle-sized segments.
Word timestamps decide *where* to split, while the final subtitle text is sliced
from the original Whisper segment text so decoded text is never lost.

For Japanese transcription, an optional conservative refinement pass can retry
only suspicious coarse segments and align subtitle ends to the existing VAD
speech spans. Normal segments are left untouched.
"""

from __future__ import annotations

import logging
import unicodedata
from collections.abc import Iterable
from dataclasses import dataclass
from difflib import SequenceMatcher
from functools import wraps
from types import SimpleNamespace
from typing import Any

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class WordTimingSplitOptions:
    enabled: bool = False
    max_duration_s: float = 5.0
    pause_threshold_s: float = 0.35
    min_duration_s: float = 0.8
    min_display_duration_s: float = 0.6
    split_on_punctuation: bool = True
    punctuation: str = "。！？!?"


@dataclass(frozen=True)
class SubtitleRefineOptions:
    enabled: bool = False
    transcribe_only: bool = True
    retry_suspicious: bool = True
    retry_max_segments: int = 24
    retry_padding_s: float = 0.25
    retry_max_source_duration_s: float = 12.0
    retry_beam_size: int = 5
    retry_temperatures: tuple[float, ...] = (0.0, 0.2, 0.4)
    retry_hallucination_silence_threshold: float = 0.8
    suspicious_logprob_threshold: float = -0.75
    suspicious_compression_ratio_threshold: float = 2.2
    suspicious_no_speech_threshold: float = 0.55
    suspicious_chars_per_second: float = 8.0
    suspicious_repetition_ratio: float = 0.72
    drop_no_speech_threshold: float = 0.75
    drop_logprob_threshold: float = -0.6
    align_end_to_vad: bool = True
    max_end_extension_s: float = 0.8
    vad_match_tolerance_s: float = 0.08


@dataclass(frozen=True)
class SubtitleSegment:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class VadSpan:
    start: float
    end: float


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
        split_on_punctuation=_coerce_bool(value.get("split_on_punctuation"), default=defaults.split_on_punctuation),
        punctuation=str(value.get("punctuation", defaults.punctuation)),
    )


def _parse_temperatures(value: Any, defaults: tuple[float, ...]) -> tuple[float, ...]:
    if not isinstance(value, (list, tuple)):
        return defaults
    temperatures = tuple(float(item) for item in value)
    return temperatures or defaults


def parse_subtitle_refine_options(value: Any) -> SubtitleRefineOptions:
    defaults = SubtitleRefineOptions()

    if value is None:
        return defaults
    if isinstance(value, bool):
        return SubtitleRefineOptions(enabled=value)
    if not isinstance(value, dict):
        return defaults

    return SubtitleRefineOptions(
        enabled=_coerce_bool(value.get("enabled"), default=True),
        transcribe_only=_coerce_bool(value.get("transcribe_only"), default=defaults.transcribe_only),
        retry_suspicious=_coerce_bool(value.get("retry_suspicious"), default=defaults.retry_suspicious),
        retry_max_segments=max(0, int(value.get("retry_max_segments", defaults.retry_max_segments))),
        retry_padding_s=max(0.0, float(value.get("retry_padding_s", defaults.retry_padding_s))),
        retry_max_source_duration_s=max(
            0.5,
            float(value.get("retry_max_source_duration_s", defaults.retry_max_source_duration_s)),
        ),
        retry_beam_size=max(1, int(value.get("retry_beam_size", defaults.retry_beam_size))),
        retry_temperatures=_parse_temperatures(value.get("retry_temperatures"), defaults.retry_temperatures),
        retry_hallucination_silence_threshold=max(
            0.0,
            float(
                value.get(
                    "retry_hallucination_silence_threshold",
                    defaults.retry_hallucination_silence_threshold,
                )
            ),
        ),
        suspicious_logprob_threshold=float(
            value.get("suspicious_logprob_threshold", defaults.suspicious_logprob_threshold)
        ),
        suspicious_compression_ratio_threshold=max(
            0.0,
            float(
                value.get(
                    "suspicious_compression_ratio_threshold",
                    defaults.suspicious_compression_ratio_threshold,
                )
            ),
        ),
        suspicious_no_speech_threshold=min(
            1.0,
            max(
                0.0,
                float(value.get("suspicious_no_speech_threshold", defaults.suspicious_no_speech_threshold)),
            ),
        ),
        suspicious_chars_per_second=max(
            1.0,
            float(value.get("suspicious_chars_per_second", defaults.suspicious_chars_per_second)),
        ),
        suspicious_repetition_ratio=min(
            1.0,
            max(
                0.0,
                float(value.get("suspicious_repetition_ratio", defaults.suspicious_repetition_ratio)),
            ),
        ),
        drop_no_speech_threshold=min(
            1.0,
            max(
                0.0,
                float(value.get("drop_no_speech_threshold", defaults.drop_no_speech_threshold)),
            ),
        ),
        drop_logprob_threshold=float(value.get("drop_logprob_threshold", defaults.drop_logprob_threshold)),
        align_end_to_vad=_coerce_bool(value.get("align_end_to_vad"), default=defaults.align_end_to_vad),
        max_end_extension_s=max(
            0.0,
            float(value.get("max_end_extension_s", defaults.max_end_extension_s)),
        ),
        vad_match_tolerance_s=max(
            0.0,
            float(value.get("vad_match_tolerance_s", defaults.vad_match_tolerance_s)),
        ),
    )


def _compact_text(text: Any) -> str:
    return "".join(str(text or "").split())


def _quality_text(text: Any) -> str:
    compact = _compact_text(text)
    return "".join(
        char
        for char in compact
        if not unicodedata.category(char).startswith(("P", "Z"))
    )


def _float_attr(segment: Any, name: str) -> float | None:
    value = getattr(segment, name, None)
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _segment_duration_s(segment: Any) -> float:
    return max(0.0, float(segment.end) - float(segment.start))


def _max_ngram_repetition_ratio(text: str) -> float:
    if len(text) < 12:
        return 0.0

    best = 0.0
    for size in range(1, min(4, len(text)) + 1):
        counts: dict[str, int] = {}
        for index in range(0, len(text) - size + 1):
            ngram = text[index : index + size]
            counts[ngram] = counts.get(ngram, 0) + 1
        if not counts:
            continue
        max_count = max(counts.values())
        if max_count < 3:
            continue
        best = max(best, min(1.0, (max_count * size) / len(text)))
    return best


def is_suspicious_segment(segment: Any, options: SubtitleRefineOptions) -> bool:
    text = _quality_text(getattr(segment, "text", ""))
    if not text:
        return False

    avg_logprob = _float_attr(segment, "avg_logprob")
    compression_ratio = _float_attr(segment, "compression_ratio")
    no_speech_prob = _float_attr(segment, "no_speech_prob")

    if compression_ratio is not None and compression_ratio >= options.suspicious_compression_ratio_threshold:
        return True
    if avg_logprob is not None and avg_logprob <= options.suspicious_logprob_threshold:
        return True
    if (
        no_speech_prob is not None
        and no_speech_prob >= options.suspicious_no_speech_threshold
        and (avg_logprob is None or avg_logprob <= -0.45)
    ):
        return True

    duration_s = max(0.05, _segment_duration_s(segment))
    chars_per_second = len(text) / duration_s
    if len(text) >= 6 and chars_per_second >= options.suspicious_chars_per_second:
        return True

    repetition_ratio = _max_ngram_repetition_ratio(text)
    return repetition_ratio >= options.suspicious_repetition_ratio


def _strong_non_speech(segment: Any, options: SubtitleRefineOptions) -> bool:
    avg_logprob = _float_attr(segment, "avg_logprob")
    no_speech_prob = _float_attr(segment, "no_speech_prob")
    compression_ratio = _float_attr(segment, "compression_ratio")

    if (
        no_speech_prob is not None
        and no_speech_prob >= options.drop_no_speech_threshold
        and (avg_logprob is None or avg_logprob <= options.drop_logprob_threshold)
    ):
        return True
    if avg_logprob is not None and avg_logprob <= -1.2:
        return True
    return compression_ratio is not None and compression_ratio >= 3.0


def _segment_quality_score(segment: Any, options: SubtitleRefineOptions) -> float:
    avg_logprob = _float_attr(segment, "avg_logprob")
    compression_ratio = _float_attr(segment, "compression_ratio")
    no_speech_prob = _float_attr(segment, "no_speech_prob")

    score = avg_logprob if avg_logprob is not None else -0.5
    if compression_ratio is not None:
        score -= max(0.0, compression_ratio - 1.8) * 0.35
    if no_speech_prob is not None:
        score -= max(0.0, no_speech_prob - 0.25) * 0.35

    text = _quality_text(getattr(segment, "text", ""))
    duration_s = max(0.05, _segment_duration_s(segment))
    chars_per_second = len(text) / duration_s if text else 0.0
    score -= max(0.0, chars_per_second - options.suspicious_chars_per_second) * 0.03
    score -= _max_ngram_repetition_ratio(text) * 0.2
    return score


def _segments_quality_score(segments: list[Any], options: SubtitleRefineOptions) -> float:
    if not segments:
        return float("-inf")

    weighted_score = 0.0
    total_weight = 0.0
    for segment in segments:
        weight = max(0.1, _segment_duration_s(segment))
        weighted_score += _segment_quality_score(segment, options) * weight
        total_weight += weight
    return weighted_score / total_weight


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

    compact_target_boundaries = [_map_compact_boundary(source, target, boundary) for boundary in source_boundaries]
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
        for normalized in (_normalize_word(word, float(segment.start), float(segment.end)) for word in raw_words)
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
        if options.split_on_punctuation and ends_with_punctuation and current_duration_s >= options.min_duration_s:
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


def _apply_minimum_display_duration(segments: list[Any], options: WordTimingSplitOptions) -> list[SubtitleSegment]:
    """Extend extremely short subtitles when there is free timeline space.

    Extension never overlaps the following subtitle and never moves the start
    earlier, so it cannot bridge a silence before the spoken line.
    """

    result: list[SubtitleSegment] = []
    for index, segment in enumerate(segments):
        start = float(segment.start)
        end = float(segment.end)
        text = str(segment.text).strip()

        if options.min_display_duration_s > 0 and end - start < options.min_display_duration_s:
            desired_end = start + options.min_display_duration_s
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

    yield from _apply_minimum_display_duration(split_segments, options)


def _parse_vad_spans(clip_timestamps: Any) -> list[VadSpan]:
    if not isinstance(clip_timestamps, (list, tuple)):
        return []

    spans: list[VadSpan] = []
    if clip_timestamps and isinstance(clip_timestamps[0], dict):
        for item in clip_timestamps:
            try:
                start = float(item["start"])
                end = float(item["end"])
            except (KeyError, TypeError, ValueError):
                continue
            if end > start:
                spans.append(VadSpan(start=start, end=end))
        return spans

    values: list[float] = []
    for item in clip_timestamps:
        try:
            values.append(float(item))
        except (TypeError, ValueError):
            return []

    for index in range(0, len(values) - 1, 2):
        start = values[index]
        end = values[index + 1]
        if end > start:
            spans.append(VadSpan(start=start, end=end))
    return spans


def align_segment_ends_to_vad(
    segments: Iterable[Any],
    clip_timestamps: Any,
    options: SubtitleRefineOptions,
) -> list[SubtitleSegment]:
    items = list(segments)
    spans = _parse_vad_spans(clip_timestamps)
    if not options.align_end_to_vad or options.max_end_extension_s <= 0 or not spans:
        return [
            SubtitleSegment(start=float(item.start), end=float(item.end), text=str(item.text).strip())
            for item in items
        ]

    result: list[SubtitleSegment] = []
    for index, segment in enumerate(items):
        start = float(segment.start)
        end = float(segment.end)
        text = str(segment.text).strip()
        next_start = float(items[index + 1].start) if index + 1 < len(items) else None

        best_span: VadSpan | None = None
        best_overlap = 0.0
        for span in spans:
            if span.start > end + options.vad_match_tolerance_s:
                break
            if span.end < start - options.vad_match_tolerance_s:
                continue

            overlap = max(0.0, min(end, span.end) - max(start, span.start))
            end_inside = span.start - options.vad_match_tolerance_s <= end <= span.end + options.vad_match_tolerance_s
            if (overlap > best_overlap or (best_span is None and end_inside)) and span.end > end:
                best_span = span
                best_overlap = overlap

        if best_span is not None:
            desired_end = min(best_span.end, end + options.max_end_extension_s)
            if next_start is not None:
                desired_end = min(desired_end, next_start)
            end = max(end, desired_end)

        result.append(SubtitleSegment(start=start, end=end, text=text))

    return result


def _offset_retry_segment(segment: Any, offset_s: float, source_start: float, source_end: float):
    start = max(source_start, offset_s + float(segment.start))
    end = min(source_end, offset_s + float(segment.end))
    if end <= start:
        return None

    words = []
    for word in getattr(segment, "words", None) or []:
        word_start = getattr(word, "start", None)
        word_end = getattr(word, "end", None)
        word_text = str(getattr(word, "word", ""))
        if word_start is None or word_end is None or not word_text.strip():
            continue
        adjusted_start = max(start, offset_s + float(word_start))
        adjusted_end = min(end, offset_s + float(word_end))
        if adjusted_end > adjusted_start:
            words.append(SimpleNamespace(start=adjusted_start, end=adjusted_end, word=word_text))

    return SimpleNamespace(
        start=start,
        end=end,
        text=str(getattr(segment, "text", "")).strip(),
        avg_logprob=getattr(segment, "avg_logprob", None),
        compression_ratio=getattr(segment, "compression_ratio", None),
        no_speech_prob=getattr(segment, "no_speech_prob", None),
        temperature=getattr(segment, "temperature", None),
        words=words or None,
    )


def _retry_segment(
    transcribe_owner: Any,
    original_transcribe: Any,
    audio_input: Any,
    segment: Any,
    base_kwargs: dict[str, Any],
    options: SubtitleRefineOptions,
) -> list[Any] | None:
    if isinstance(audio_input, (str, bytes)) or not hasattr(audio_input, "__len__") or not hasattr(audio_input, "__getitem__"):
        return None
    if not hasattr(transcribe_owner, "feature_extractor"):
        return None

    source_start = float(segment.start)
    source_end = float(segment.end)
    source_duration = max(0.0, source_end - source_start)
    if source_duration <= 0 or source_duration > options.retry_max_source_duration_s:
        return None

    sampling_rate = int(getattr(transcribe_owner.feature_extractor, "sampling_rate", 16_000))
    total_samples = len(audio_input)
    total_duration = total_samples / sampling_rate
    window_start = max(0.0, source_start - options.retry_padding_s)
    window_end = min(total_duration, source_end + options.retry_padding_s)
    start_sample = max(0, min(total_samples, int(round(window_start * sampling_rate))))
    end_sample = max(start_sample, min(total_samples, int(round(window_end * sampling_rate))))
    if end_sample <= start_sample:
        return None

    retry_audio = audio_input[start_sample:end_sample]
    retry_kwargs = dict(base_kwargs)
    retry_kwargs.pop("clip_timestamps", None)
    retry_kwargs.pop("vad_parameters", None)
    retry_kwargs.pop("audio", None)
    retry_kwargs["vad_filter"] = False
    retry_kwargs["word_timestamps"] = True
    retry_kwargs["condition_on_previous_text"] = False
    retry_kwargs["beam_size"] = options.retry_beam_size
    retry_kwargs["temperature"] = list(options.retry_temperatures)
    retry_kwargs["compression_ratio_threshold"] = 2.4
    retry_kwargs["log_prob_threshold"] = -1.0
    retry_kwargs["no_speech_threshold"] = 0.6
    retry_kwargs["hallucination_silence_threshold"] = options.retry_hallucination_silence_threshold
    retry_kwargs["initial_prompt"] = None
    retry_kwargs["prefix"] = None

    try:
        retry_iter, _retry_info = original_transcribe(transcribe_owner, retry_audio, **retry_kwargs)
        retry_segments = list(retry_iter)
    except Exception as exc:
        logger.debug("Suspicious segment retry failed: %s", exc)
        return None

    adjusted = []
    for retry_segment in retry_segments:
        candidate = _offset_retry_segment(retry_segment, window_start, source_start, source_end)
        if candidate is not None and candidate.text:
            adjusted.append(candidate)
    return adjusted


def refine_suspicious_segments(
    transcribe_owner: Any,
    original_transcribe: Any,
    audio_input: Any,
    segments: Iterable[Any],
    base_kwargs: dict[str, Any],
    options: SubtitleRefineOptions,
) -> list[Any]:
    items = list(segments)
    if not options.retry_suspicious or options.retry_max_segments <= 0:
        return items

    result: list[Any] = []
    retried = 0
    replaced = 0
    dropped = 0

    for segment in items:
        if retried >= options.retry_max_segments or not is_suspicious_segment(segment, options):
            result.append(segment)
            continue

        retry_segments = _retry_segment(
            transcribe_owner,
            original_transcribe,
            audio_input,
            segment,
            base_kwargs,
            options,
        )
        if retry_segments is None:
            result.append(segment)
            continue

        retried += 1
        if not retry_segments:
            if _strong_non_speech(segment, options):
                dropped += 1
                continue
            result.append(segment)
            continue

        retry_is_suspicious = any(is_suspicious_segment(item, options) for item in retry_segments)
        original_score = _segment_quality_score(segment, options)
        retry_score = _segments_quality_score(retry_segments, options)

        if not retry_is_suspicious or retry_score >= original_score + 0.05:
            result.extend(retry_segments)
            replaced += 1
        else:
            result.append(segment)

    if retried:
        logger.info(
            "Subtitle refine: retried %s suspicious segment(s), replaced %s, dropped %s",
            retried,
            replaced,
            dropped,
        )
    return result


def _patch_transcribe_class(cls: Any) -> bool:
    original = getattr(cls, "transcribe", None)
    if original is None or getattr(original, "_chickenrice_word_timing_split", False):
        return False

    @wraps(original)
    def patched(self, *args, **kwargs):
        raw_split_options = kwargs.pop("word_timing_split", None)
        raw_refine_options = kwargs.pop("subtitle_refine", None)
        split_options = parse_word_timing_split_options(raw_split_options)
        refine_options = parse_subtitle_refine_options(raw_refine_options)

        task = str(kwargs.get("task", "transcribe")).strip().lower()
        refine_enabled = refine_options.enabled and (not refine_options.transcribe_only or task == "transcribe")

        if not split_options.enabled and not refine_enabled:
            return original(self, *args, **kwargs)

        if split_options.enabled:
            kwargs["word_timestamps"] = True

        segments, info = original(self, *args, **kwargs)
        items = list(segments)

        if refine_enabled and refine_options.retry_suspicious:
            audio_input = args[0] if args else kwargs.get("audio")
            items = refine_suspicious_segments(
                self,
                original,
                audio_input,
                items,
                kwargs,
                refine_options,
            )

        if split_options.enabled:
            processed: list[Any] = list(split_segments_by_words(items, split_options))
        else:
            processed = items

        if refine_enabled and refine_options.align_end_to_vad:
            processed = align_segment_ends_to_vad(
                processed,
                kwargs.get("clip_timestamps"),
                refine_options,
            )

        return iter(processed), info

    patched._chickenrice_word_timing_split = True  # type: ignore[attr-defined]
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
