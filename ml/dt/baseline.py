"""Rule-based classifier. Must match firmware stepdet/rules.c exactly."""
import numpy as np

from .protocol import StepClass
from .windows import WIN_PRE

RULE_MOVE_MIN = 40.0
RULE_KICK_MIN = 90.0


def classify(w: np.ndarray) -> tuple[StepClass, int]:
    """w: (60, 9) int8. Returns (class, confidence 0..255)."""
    x = w[:WIN_PRE].astype(np.float32)
    vx = np.cumsum(x[:, 6])
    vy = np.cumsum(x[:, 7])
    dx = vx.sum() / WIN_PRE
    dy = vy.sum() / WIN_PRE
    mag = float(np.hypot(dx, dy))
    conf = int(min(255.0, mag * 2.0))
    if mag < RULE_MOVE_MIN:
        return StepClass.IN_PLACE, 200
    if abs(dx) >= abs(dy):
        if dx > 0:
            return (StepClass.KICK if mag > RULE_KICK_MIN else StepClass.FORWARD), conf
        return StepClass.BACK, conf
    return (StepClass.SIDE_OUT if dy > 0 else StepClass.CROSS), conf
