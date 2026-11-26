# Anytime-Valid Inference for Multinomial Count Data

A pinned citation, not a copy of the paper.

- **Authors:** Michael Lindon (Netflix), Alan Malek (DeepMind).
- **arXiv:** [2011.03567](https://arxiv.org/abs/2011.03567), version 2 (28 May 2022); PDF at <https://arxiv.org/pdf/2011.03567v2>.
- **SHA-256 of the version 2 PDF:** `9f4b03576f54c80f3d4244244c8592c9c7f3e6265841c4679fcc0dc3648a9aab`.

## Why It Is Cited

It builds a sequential test on counts that can be monitored after every observation while bounding the false-rejection probability by `u`.
Its Section 2 is a Dirichlet-multinomial mixture of likelihood ratios that rejects when the posterior odds reach `1/u` (Theorem 2.2).
Its Section 3 applies that test to arms receiving units with fixed assignment probabilities and a shared, time-varying base rate.
The arm each event comes from is then a multinomial draw that depends only on the assignment probabilities and the arms' log rate ratios (equation 12), so the time-varying rate drops out.

Splice's canary verdicts (`src/sprt.lisp`) take their formulas from these two sections.
Lindon, Sanden and Shirikian (KDD 2022), pinned beside this file, cite it as their reference 15.

## Why the Paper Is Not Vendored

arXiv distributes the paper under its non-exclusive distribution license, which grants distribution rights to arXiv alone.
A copy committed here would redistribute it, so this file pins the version instead.
Fetch the PDF from the arXiv link above; version 2 is the one splice's design was checked against.
