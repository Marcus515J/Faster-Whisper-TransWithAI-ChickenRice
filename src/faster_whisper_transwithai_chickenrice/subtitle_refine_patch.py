"""Second-pass refinement fixes for Japanese transcription.

This patch layer keeps the existing word-timing splitter intact while tightening
two behaviours discovered in the 30-minute regression sample:

- retry selection now considers local word-timing bursts and word confidence,
  then spends the retry budget on the worst candidates across the whole file;
- VAD end alignment only snaps to a nearby *actual VAD tail* instead of adding
  the maximum extension to every subtitle inside a long speech span.
"""

from __future__ import annotations

import logging
from types import SimpleNamespace
from typing import Any

from . import word_timing_split as wts

logger = logging.getLogger(__name__)

_ORIGINAL_IS_SUSPICIOUS = getattr(wts, "_original_is_suspicious_segment_v2", wts.is_suspicious_segment)

_LOCAL_GAP_S = 0.35
_LOCAL_WORD_CONFIDENCE_THRESHOLD = 0.50
_LOCAL_LOGPROB_THRESHOLD = -0.50
_LOCAL_NO_SPEECH_THRESHOLD = 0.35


def _word_items(segment: Any) -> list[SimpleNamespace]:
    items: list[SimpleNamespace] = []
    for word in getattr(segment, "words", None) or []:
        start = getattr(word, "start", None)
        end = getattr(word, "end", None)
        text = str(getattr(word, "word", "")).strip()
        if start is None or end is None or not text:
            continue
        start_f = float(start)
        end_f = float(end)
        if end_f <= start_f:
            continue
        probability = getattr(word, "probability", None)
        try:
            probability_f = float(probability) if probability is not None else None
        except (TypeError, ValueError):
            probability_f = None
        items.append(
            SimpleNamespace(
                start=start_f,
                end=end_f,
                word=text,
                probability=probability_f,
            )
        )
    return items


def _word_groups(segment: Any) -> list[list[SimpleNamespace]]:
    words = _word_items(segment)
    if not words:
        return []

    groups: list[list[SimpleNamespace]] = []
    current: list[SimpleNamespace] = []
    previous: SimpleNamespace | None = None

    for word in words:
        if current and previous is not None:
            gap_s = max(0.0, word.start - previous.end)
            if gap_s >= _LOCAL_GAP_S:
                groups.append(current)
                current = []

        current.append(word)
        previous = word

        if word.word.rstrip().endswith(("。", "！", "？", "!", "?")):
            groups.append(current)
            current = []
            previous = None

    if current:
        groups.append(current)
    return groups


def _local_text_rate(segment: Any) -> float:
    best = 0.0
    for group in _word_groups(segment):
        text = wts._quality_text("".join(word.word for word in group))
        if len(text) < 5:
            continue
        duration_s = max(0.05, group[-1].end - group[0].start)
        best = max(best, len(text) / duration_s)
    return best


def _mean_word_probability(segment: Any) -> float | None:
    probabilities = [word.probability for word in _word_items(segment) if word.probability is not None]
    if not probabilities:
        return None
    return sum(probabilities) / len(probabilities)


def is_suspicious_segment(segment: Any, options: wts.SubtitleRefineOptions) -> bool:
    if _ORIGINAL_IS_SUSPICIOUS(segment, options):
        return True

    avg_logprob = wts._float_attr(segment, "avg_logprob")
    no_speech_prob = wts._float_attr(segment, "no_speech_prob")
    word_probability = _mean_word_probability(segment)

    if avg_logprob is not None and avg_logprob <= _LOCAL_LOGPROB_THRESHOLD:
        return True
    if (
        no_speech_prob is not None
        and no_speech_prob >= _LOCAL_NO_SPEECH_THRESHOLD
        and (avg_logprob is None or avg_logprob <= -0.30)
    ):
        return True
    if word_probability is not None and word_probability <= _LOCAL_WORD_CONFIDENCE_THRESHOLD:
        return True

    local_rate = _local_text_rate(segment)
    return local_rate >= options.suspicious_chars_per_second


def _candidate_score(segment: Any, options: wts.SubtitleRefineOptions) -> float:
    score = wts._segment_quality_score(segment, options)

    word_probability = _mean_word_probability(segment)
    if word_probability is not None:
        score -= max(0.0, _LOCAL_WORD_CONFIDENCE_THRESHOLD - word_probability) * 1.5

    local_rate = _local_text_rate(segment)
    score -= max(0.0, local_rate - 5.0) * 0.08

    avg_logprob = wts._float_attr(segment, "avg_logprob")
    if avg_logprob is not None:
        score -= max(0.0, _LOCAL_LOGPROB_THRESHOLD - avg_logprob) * 0.5

    return score


def _segments_candidate_score(
    segments: list[Any],
    options: wts.SubtitleRefineOptions,
) -> float:
    if not segments:
        return float("-inf")

    weighted = 0.0
    total = 0.0
    for segment in segments:
        weight = max(0.1, wts._segment_duration_s(segment))
        weighted += _candidate_score(segment, options) * weight
        total += weight
    return weighted / total


def refine_suspicious_segments(
    transcribe_owner: Any,
    original_transcribe: Any,
    audio_input: Any,
    segments: Any,
    base_kwargs: dict[str, Any],
    options: wts.SubtitleRefineOptions,
) -> list[Any]:
    items = list(segments)
    if not options.retry_suspicious or options.retry_max_segments <= 0:
        return items

    candidates: list[tuple[float, int]] = []
    for index, segment in enumerate(items):
        duration_s = wts._segment_duration_s(segment)
        if duration_s <= 0 or duration_s > options.retry_max_source_duration_s:
            continue
        if is_suspicious_segment(segment, options):
            candidates.append((_candidate_score(segment, options), index))

    candidates.sort(key=lambda item: item[0])
    selected = {index for _score, index in candidates[: options.retry_max_segments]}

    result: list[Any] = []
    retried = 0
    replaced = 0
    dropped = 0

    for index, segment in enumerate(items):
        if index not in selected:
            result.append(segment)
            continue

        retry_segments = wts._retry_segment(
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
            if wts._strong_non_speech(segment, options):
                dropped += 1
                continue
            result.append(segment)
            continue

        retry_is_suspicious = any(is_suspicious_segment(item, options) for item in retry_segments)
        original_score = _candidate_score(segment, options)
        retry_score = _segments_candidate_score(retry_segments, options)

        if not retry_is_suspicious or retry_score >= original_score + 0.05:
            result.extend(retry_segments)
            replaced += 1
        else:
            result.append(segment)

    logger.info(
        "Subtitle refine: candidates %s, retried %s, replaced %s, dropped %s",
        len(candidates),
        retried,
        replaced,
        dropped,
    )
    return result


def align_segment_ends_to_vad(
    segments: Any,
    clip_timestamps: Any,
    options: wts.SubtitleRefineOptions,
) -> list[wts.SubtitleSegment]:
    items = list(segments)
    spans = wts._parse_vad_spans(clip_timestamps)
    if not options.align_end_to_vad or options.max_end_extension_s <= 0 or not spans:
        return [
            wts.SubtitleSegment(
                start=float(item.start),
                end=float(item.end),
                text=str(item.text).strip(),
            )
            for item in items
        ]

    result: list[wts.SubtitleSegment] = []
    for index, segment in enumerate(items):
        start = float(segment.start)
        end = float(segment.end)
        text = str(segment.text).strip()
        next_start = float(items[index + 1].start) if index + 1 < len(items) else None

        best_tail: float | None = None
        for span in spans:
            if span.start > end + options.max_end_extension_s + options.vad_match_tolerance_s:
                break
            if span.end < start - options.vad_match_tolerance_s:
                continue

            tail_gap = span.end - end
            if tail_gap <= 0:
                continue
            if tail_gap > options.max_end_extension_s + options.vad_match_tolerance_s:
                continue

            overlaps = min(end, span.end) - max(start, span.start) > 0
            end_near_span = span.start - options.vad_match_tolerance_s <= end <= span.end
            if not overlaps and not end_near_span:
                continue

            if best_tail is None or span.end < best_tail:
                best_tail = span.end

        if best_tail is not None:
            desired_end = best_tail
            if next_start is not None:
                desired_end = min(desired_end, next_start)
            end = max(end, desired_end)

        result.append(wts.SubtitleSegment(start=start, end=end, text=text))

    return result


def install_subtitle_refine_patch() -> bool:
    if getattr(wts, "_subtitle_refine_v2_installed", False):
        return False

    if not hasattr(wts, "_original_is_suspicious_segment_v2"):
        wts.__dict__["_original_is_suspicious_segment_v2"] = wts.is_suspicious_segment

    wts.__dict__["is_suspicious_segment"] = is_suspicious_segment
    wts.__dict__["refine_suspicious_segments"] = refine_suspicious_segments
    wts.__dict__["align_segment_ends_to_vad"] = align_segment_ends_to_vad
    wts.__dict__["_subtitle_refine_v2_installed"] = True
    return True
