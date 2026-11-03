#!/usr/bin/env python3
"""Train the step classifier with leave-one-dancer-out cross-validation.

Usage: train.py runs/windows.npz [--epochs 40] [--out runs/model.keras]

Prints per-fold accuracy and a pooled confusion matrix, then trains a final
model on all data and saves it.
"""
import argparse

import numpy as np
import tensorflow as tf
from sklearn.metrics import confusion_matrix

from dt.protocol import N_CLASSES
from dt.windows import CHANNELS, WIN_LEN


def build() -> tf.keras.Model:
    inp = tf.keras.Input(shape=(WIN_LEN, len(CHANNELS)), dtype=tf.float32)
    x = tf.keras.layers.Conv1D(16, 5, padding="same", activation="relu")(inp)
    x = tf.keras.layers.MaxPool1D(2)(x)
    x = tf.keras.layers.Conv1D(32, 5, padding="same", activation="relu")(x)
    x = tf.keras.layers.GlobalAveragePooling1D()(x)
    out = tf.keras.layers.Dense(N_CLASSES, activation="softmax")(x)
    m = tf.keras.Model(inp, out)
    m.compile(optimizer="adam", loss="sparse_categorical_crossentropy", metrics=["accuracy"])
    return m


def _small_rotation(max_yaw_deg: float = 10.0, max_tilt_deg: float = 5.0) -> np.ndarray:
    """Random rotation matrix: up to ±max_yaw about z, ±max_tilt about x and y.
    Models leftover calibration error (imperfect still pose or slide)."""
    yaw, rx, ry = np.radians(np.random.uniform(-1, 1, 3) * [max_yaw_deg, max_tilt_deg, max_tilt_deg])
    cz, sz, cx, sx, cy, sy = np.cos(yaw), np.sin(yaw), np.cos(rx), np.sin(rx), np.cos(ry), np.sin(ry)
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    rxm = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    rym = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    return (rz @ rym @ rxm).astype(np.float32)


def augment(x: np.ndarray) -> np.ndarray:
    """Random ±3-sample time shift, ±10% gain, and a small random rotation applied
    to each 3-vector group (sensor accel, gyro, foot accel) so the model does not
    learn the exact strap angle. Input/output int8-range floats."""
    out = np.empty_like(x)
    for i in range(len(x)):
        s = np.random.randint(-3, 4)
        w = np.roll(x[i], s, axis=0) * np.random.uniform(0.9, 1.1)
        r = _small_rotation()
        for c0 in (0, 3, 6):
            w[:, c0:c0 + 3] = w[:, c0:c0 + 3] @ r.T
        out[i] = w
    return np.clip(out, -128, 127)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("npz")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--out", default="runs/model.keras")
    a = ap.parse_args()

    d = np.load(a.npz)
    x = d["x"].astype(np.float32)  # int8 values as floats; cnn.c on the node feeds the same values
    y, dancer = d["y"], d["dancer"]

    cm = np.zeros((N_CLASSES, N_CLASSES), dtype=int)
    for held in np.unique(dancer):
        tr, te = dancer != held, dancer == held
        m = build()
        m.fit(augment(x[tr]), y[tr], epochs=a.epochs, batch_size=64, verbose=0)
        pred = m.predict(x[te], verbose=0).argmax(1)
        acc = (pred == y[te]).mean()
        cm += confusion_matrix(y[te], pred, labels=list(range(N_CLASSES)))
        print(f"held-out {held:>10}: n={te.sum():4d} acc={acc:.3f}")
    print("pooled accuracy", np.trace(cm) / cm.sum())
    print(cm)

    final = build()
    final.fit(augment(x), y, epochs=a.epochs, batch_size=64, verbose=0)
    final.save(a.out)
    print("saved", a.out, "params", final.count_params())


if __name__ == "__main__":
    main()
