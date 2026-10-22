"""Enums shared with the firmware and app. Mirror of dt_protocol.h."""
from enum import IntEnum

PROTOCOL_VERSION = 1


class StepClass(IntEnum):
    NONE = 0
    IN_PLACE = 1
    FORWARD = 2
    BACK = 3
    SIDE_OUT = 4
    CROSS = 5
    KICK = 6


class Verdict(IntEnum):
    UNJUDGED = 0
    CORRECT = 1
    OFF_BEAT = 2
    WRONG_STEP = 3
    MISSED = 4
    EXTRA = 5


CLASS_NAMES = {
    "none": StepClass.NONE,
    "in_place": StepClass.IN_PLACE,
    "forward": StepClass.FORWARD,
    "back": StepClass.BACK,
    "side_out": StepClass.SIDE_OUT,
    "cross": StepClass.CROSS,
    "kick": StepClass.KICK,
}
N_CLASSES = len(StepClass)
