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


def augment(x: np.ndarray) -> np.ndarray:
    """Random ±3-sample time shift and ±10% gain. Input/output int8-range floats."""
    out = np.empty_like(x)
    for i in range(len(x)):
        s = np.random.randint(-3, 4)
        out[i] = np.roll(x[i], s, axis=0) * np.random.uniform(0.9, 1.1)
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
