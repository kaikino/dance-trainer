"""Window geometry and int8 quantization. Must match firmware stepdet.h / stepdet.c."""
import numpy as np
import pandas as pd

RATE_HZ = 104          # LSM6DS3 ODR; the firmware takes every sample
WIN_PRE = 100          # ≈0.96 s before the strike: a slow swing plus the stance before it
WIN_POST = 40          # ≈0.38 s after: the foot settling (heel drop, weight transfer; rules.c needs it still)
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


U32 = 1 << 32
QUAT_SCALE = 16384.0   # app CSVs store qw..qz as int × 16384 (docs/data-format.md)


def unwrap_u32(t) -> np.ndarray:
    """Node times (u32 µs, wraps every ~71.6 min) → int64, adding 2^32 at every
    step back of more than 2^31 (and taking it off again at a step forward of more
    than 2^31: a late sample from before the wrap). Idempotent on an already-
    unwrapped series; small out-of-order steps are left for the caller to sort."""
    t = np.asarray(t, dtype=np.int64).copy()
    if len(t) > 1:
        d = np.diff(t)
        wraps = np.cumsum((d < -(U32 >> 1)).astype(np.int64) - (d > (U32 >> 1)))
        t[1:] += wraps * U32
    return t


def u32_delta(a, b):
    """a − b on the u32 µs clock, signed in [−2^31, 2^31). Same as the app's u32DeltaUs."""
    d = (np.asarray(a, dtype=np.int64) - np.asarray(b, dtype=np.int64)) % U32
    return np.where(d >= (U32 >> 1), d - U32, d)


def unwrap_near(t_raw, ref: int) -> np.ndarray:
    """Node times in file order (one node) → unwrapped values, each placed within
    2^31 of the previous one, the first within 2^31 of `ref` (an unwrapped time)."""
    out = np.empty(len(t_raw), dtype=np.int64)
    for i, t in enumerate(np.asarray(t_raw, dtype=np.int64)):
        ref = int(ref + u32_delta(t, ref))
        out[i] = ref
    return out


def has_app_time(df: pd.DataFrame) -> bool:
    """Newer app exports carry t_app_ms on every row (stream and events)."""
    return "t_app_ms" in df.columns and pd.to_numeric(df["t_app_ms"], errors="coerce").notna().any()


def load_stream(path) -> pd.DataFrame:
    """An L.csv / R.csv ready for searchsorted. With a t_app_ms column (newer app
    exports) rows are ordered by app time, which survives both the u32 wrap and a
    node reboot (its clock restarts; the app re-syncs and times rows with the new
    offset); t_node_us is only unwrapped. Without it, t_node_us is unwrapped,
    sorted and de-duplicated."""
    df = pd.read_csv(path)
    if has_app_time(df):
        df = load_stream_frame(df)
        return df.assign(t_node_us=unwrap_u32(df["t_node_us"].to_numpy()))
    return _monotonic(df)


def _monotonic(df: pd.DataFrame) -> pd.DataFrame:
    t = unwrap_u32(df["t_node_us"].to_numpy())
    if len(t) > 1 and not np.all(np.diff(t) > 0):
        df = df.assign(t_node_us=t).sort_values("t_node_us", kind="stable")
        return df.drop_duplicates("t_node_us", keep="first").reset_index(drop=True)
    return df.assign(t_node_us=t)


def quat(df: pd.DataFrame) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """qw..qz as unit quaternions. The app writes them as int × 16384; anything
    above 1.5 in magnitude is taken to be that scale. Normalised; a zero row
    (missing) becomes identity."""
    q = df[["qw", "qx", "qy", "qz"]].to_numpy(dtype=np.float64)
    if len(q) and np.nanmax(np.abs(q)) > 1.5:
        q = q / QUAT_SCALE
    n = np.linalg.norm(q, axis=1, keepdims=True)
    bad = ~np.isfinite(n[:, 0]) | (n[:, 0] < 1e-6)
    q = np.where(bad[:, None], np.array([1.0, 0.0, 0.0, 0.0]), q / np.where(bad[:, None], 1.0, n))
    q = q.astype(np.float32)
    return q[:, 0], q[:, 1], q[:, 2], q[:, 3]


def foot_accel(df: pd.DataFrame, foot: str) -> np.ndarray:
    """Sensor accel (mg, calibrated sensor frame) → foot frame in g: leveled, heading
    removed so +x = toe direction, gravity removed, y mirrored for the right foot
    so +y = outward on both feet. Same math as fusion.c fusion_task()."""
    w, x, y, z = quat(df)
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
    """One (WIN_LEN, 9) int8 window centred on the strike, or None if out of range.

    The stream's t_node_us may be raw u32 (it is unwrapped here) or already
    unwrapped (load_stream). t_strike_us should be on the same unwrapped scale
    (windows.py does that with unwrap_near); a raw u32 strike on a wrapped stream
    is placed at its first occurrence inside the stream."""
    df = _monotonic(df)
    t = df["t_node_us"].to_numpy()
    if len(t) == 0:
        return None
    t_strike_us = int(t_strike_us)
    if t_strike_us < U32 and t[-1] >= U32:
        k0 = max(0, (int(t[0]) - t_strike_us) // U32)
        for k in range(k0, int(t[-1]) // U32 + 1):
            if t[0] <= t_strike_us + k * U32 <= t[-1]:
                t_strike_us += k * U32
                break
    i = int(np.searchsorted(t, t_strike_us))
    if i - WIN_PRE < 0 or i + WIN_POST > len(df):
        return None
    return _window(df.iloc[i - WIN_PRE : i + WIN_POST], foot)


def cut_app(df: pd.DataFrame, t_strike_app_ms: float, foot: str, max_gap_samples: float = 3) -> np.ndarray | None:
    """Like cut(), but locates the strike by app time (t_app_ms on the stream rows
    and the event; newer app exports). None if out of range, or if the window's
    rows span more than max_gap_samples periods beyond WIN_LEN (lost batches or a
    reconnect inside it, so the samples would not be contiguous)."""
    t = pd.to_numeric(df["t_app_ms"], errors="coerce").to_numpy(dtype=np.float64)
    if len(t) == 0 or not np.isfinite(t_strike_app_ms):
        return None
    if not np.all(np.diff(t) > 0):
        df = load_stream_frame(df)
        t = df["t_app_ms"].to_numpy(dtype=np.float64)
    i = int(np.searchsorted(t, t_strike_app_ms))
    if i - WIN_PRE < 0 or i + WIN_POST > len(df):
        return None
    period_ms = 1000.0 / RATE_HZ
    if t[i + WIN_POST - 1] - t[i - WIN_PRE] > (WIN_LEN - 1 + max_gap_samples) * period_ms:
        return None
    return _window(df.iloc[i - WIN_PRE : i + WIN_POST], foot)


def load_stream_frame(df: pd.DataFrame) -> pd.DataFrame:
    """Rows with a t_app_ms, ordered and de-duplicated by it."""
    df = df.assign(t_app_ms=pd.to_numeric(df["t_app_ms"], errors="coerce")).dropna(subset=["t_app_ms"])
    return df.sort_values("t_app_ms", kind="stable").drop_duplicates("t_app_ms", keep="first").reset_index(drop=True)


def _window(sl: pd.DataFrame, foot: str) -> np.ndarray | None:
    """(WIN_LEN, 9) int8 from WIN_LEN contiguous stream rows; None if any of
    them has an empty cell (older exports wrote half batches: accel, no gyro)."""
    if sl[["ax", "ay", "az", "gx", "gy", "gz", "qw", "qx", "qy", "qz"]].isna().to_numpy().any():
        return None
    sensor = sl[["ax", "ay", "az"]].to_numpy(dtype=np.float32) / 1000.0
    gyro = sl[["gx", "gy", "gz"]].to_numpy(dtype=np.float32) / 10.0
    if foot == MIRRORED_FOOT:
        sensor, gyro = mirror_sensor(sensor, gyro)
    foot_fr = foot_accel(sl, foot)
    return quantize(np.concatenate([sensor, gyro, foot_fr], axis=1))
