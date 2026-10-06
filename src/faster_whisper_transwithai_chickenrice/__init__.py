"""
faster_whisper_transwithai_chickenrice - Custom VAD injection for faster_whisper
"""

from .injection import (
    VadInjectionContext,
    VadOptionsCompat,
    auto_inject_vad,
    inject_vad,
    is_injection_active,
    uninject_vad,
    with_vad_injection,
)
from .subtitle_refine_patch import install_subtitle_refine_patch
from .vad_manager import VadModelManager, WhisperVadModel
from .word_timing_split import install_word_timing_split_patch

# Install the optional word-timestamp splitter at package import time.
# It is inert unless generation_config passes word_timing_split.enabled=true.
install_word_timing_split_patch()
install_subtitle_refine_patch()

__version__ = "0.1.0"

__all__ = [
    "inject_vad",
    "uninject_vad",
    "VadInjectionContext",
    "with_vad_injection",
    "auto_inject_vad",
    "VadOptionsCompat",
    "is_injection_active",
    "VadModelManager",
    "WhisperVadModel",
]
