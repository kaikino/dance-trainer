"""Window geometry and int8 quantization. Must match firmware stepdet.h / stepdet.c."""
import numpy as np
import pandas as pd

RATE_HZ = 104          # LSM6DS3 ODR; the firmware takes every sample
WIN_PRE = 100          # ≈0.96 s before the strike: a slow swing plus the stance before it
WIN_POST = 20          # ≈0.19 s after: the foot settling (rules.c needs it planted)
WIN_LEN = WIN_PRE + WIN_POST
CHANNELS = ["ax", "ay", "az", "gx", "gy", "gz", "ax_f", "ay_f", "az_f"]

# Per-channel full-scale for int8: value_int8 = round(v / scale * 127). Sensor accel
# is 8 g (not the IMU's 16 g range) so the shank tilt in stance resolves to 3.6°
# per LSB; rules.c reads it. Duplicated in stepdet.c and model_weights.h (export.py).
SCALES = np.array([8, 8, 8, 2000, 2000, 2000, 8, 8, 8], dtype=np.float32)

# The node's calibrated sensor frame is +x toe, +z up, so +y is the dancer's left.
# The RIGHT foot is mirrored so +y = outward on both feet. Same as fusion.c/stepdet.c.
MIRRORED_FOOT = "R"


def quantize(x: np.ndarray) -> np.ndarray:
    """x: (..., 9) float → int8."""
    q = np.rint(x / SCALES * 127.0)
    return np.clip(q, -128, 127).astype(np.int8)


def _rotate(w, x, y, z, v: np.ndarray) -> np.ndarray:
    r = np.empty_like(v)
    r[:, 0] = (1 - 2 * (y * y + z * z)) * v[:, 0] + 2 * (x * y - w * z) * v[:, 1] + 2 * (x * z + w * y) * v[:, 2]
    r[:, 1] = 2 * (x * y + w * z) * v[:, 0] + (1 - 2 * (x * x + z * z)) * v[:, 1] + 2 * (y * z - w * x) * v[:, 2]
    r[:, 2] = 2 * (x * z - w * y) * v[:, 0] + 2 * (y * z + w * x) * v[:, 1] + (1 - 2 * (x * x + y * y)) * v[:, 2]
    return r


def foot_accel(df: pd.DataFrame, foot: str) -> np.ndarray:
    """Sensor accel (mg, calibrated sensor frame) → foot frame in g: leveled, heading
    removed so +x = toe direction, gravity removed, y mirrored for the right foot
    so +y = outward on both feet. Same math as fusion.c fusion_task()."""
    w, x, y, z = (df[c].to_numpy(dtype=np.float32) for c in ("qw", "qx", "qy", "qz"))
    a = df[["ax", "ay", "az"]].to_numpy(dtype=np.float32) / 1000.0
    a_w = _rotate(w, x, y, z, a)
    a_w[:, 2] -= 1.0
    xw = _rotate(w, x, y, z, np.tile(np.array([[1.0, 0.0, 0.0]], dtype=np.float32), (len(a), 1)))
    yaw = np.arctan2(xw[:, 1], xw[:, 0])
    c, s = np.cos(yaw), np.sin(yaw)
    out = np.empty_like(a_w)
    out[:, 0] = c * a_w[:, 0] + s * a_w[:, 1]
    out[:, 1] = -s * a_w[:, 0] + c * a_w[:, 1]
    out[:, 2] = a_w[:, 2]
    if foot == MIRRORED_FOOT:
        out[:, 1] = -out[:, 1]
    return out


def mirror_sensor(sensor: np.ndarray, gyro: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Reflect the y axis: accelerations flip y, rotation rates (axial vectors) flip
    the other two. Same as stepdet.c cut_window() on the right node."""
    sensor = sensor.copy(); gyro = gyro.copy()
    sensor[:, 1] = -sensor[:, 1]
    gyro[:, 0] = -gyro[:, 0]
    gyro[:, 2] = -gyro[:, 2]
    return sensor, gyro


def cut(df: pd.DataFrame, t_strike_us: int, foot: str) -> np.ndarray | None:
    """One (WIN_LEN, 9) int8 window centred on the strike, or None if out of range."""
    t = df["t_node_us"].to_numpy()
    i = int(np.searchsorted(t, t_strike_us))
    if i - WIN_PRE < 0 or i + WIN_POST > len(df):
        return None
    sl = df.iloc[i - WIN_PRE : i + WIN_POST]
    sensor = sl[["ax", "ay", "az"]].to_numpy(dtype=np.float32) / 1000.0
    gyro = sl[["gx", "gy", "gz"]].to_numpy(dtype=np.float32) / 10.0
    if foot == MIRRORED_FOOT:
        sensor, gyro = mirror_sensor(sensor, gyro)
    foot_fr = foot_accel(sl, foot)
    return quantize(np.concatenate([sensor, gyro, foot_fr], axis=1))
