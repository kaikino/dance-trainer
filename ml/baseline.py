#!/usr/bin/env python3
"""Accuracy of the rule-based classifier on a windows.npz. The model must beat this."""
import sys

import numpy as np
from sklearn.metrics import classification_report, confusion_matrix

from dt.baseline import classify
from dt.protocol import StepClass

d = np.load(sys.argv[1] if len(sys.argv) > 1 else "runs/windows.npz")
pred = np.array([int(classify(w)[0]) for w in d["x"]])
print(classification_report(d["y"], pred, labels=list(range(len(StepClass))), target_names=[c.name for c in StepClass], zero_division=0))
print(confusion_matrix(d["y"], pred, labels=list(range(len(StepClass)))))
