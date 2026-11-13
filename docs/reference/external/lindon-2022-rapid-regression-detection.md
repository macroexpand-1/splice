# Rapid Regression Detection in Software Deployments Through Sequential Testing

A pinned citation, not a copy of the paper.

- **Authors:** Michael Lindon, Chris Sanden, Vaché Shirikian (Netflix).
- **Venue:** Proceedings of the 28th ACM SIGKDD Conference on Knowledge Discovery and Data Mining (KDD 2022).
- **DOI:** [10.1145/3534678.3539099](https://doi.org/10.1145/3534678.3539099).
- **arXiv:** [2205.14762](https://arxiv.org/abs/2205.14762), version 2 (22 June 2022); PDF at <https://arxiv.org/pdf/2205.14762v2>.

## Why It Is Cited

It presents sequential tests for canary deployments that can be monitored continuously while strictly controlling the probability of a false detection.
The tests are of stochastic order and of equality in distribution, and the paper demonstrates them on two case studies at Netflix.
Splice's canary verdicts are designed against it.

## Why the Paper Is Not Vendored

arXiv distributes the paper under its non-exclusive distribution license, which grants distribution rights to arXiv alone.
A copy committed here would redistribute it, so this file pins the version instead.
Fetch the PDF from the arXiv link above; version 2 is the one splice's design was checked against.
