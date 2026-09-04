# Notices

This install bundle is part of Konduktor and is distributed under the Trainy
Software License, Version 1.0 — see the `LICENSE` file distributed alongside it.

## What this bundle contains

The files here are **configuration and installation tooling**: a shell
installer, Helm values files, and two Kubernetes manifests. They are original
work by Trainy, Inc.

## Third-party software this bundle installs

The installer fetches and installs software published by other projects. That
software is **not** covered by Trainy's license — each is distributed by its own
project, under its own license and its own terms. This bundle only supplies
configuration for it.

| Component | Source | Installed as |
|---|---|---|
| VictoriaMetrics operator, and the vmagent it runs | The VictoriaMetrics project | Helm chart `vm/victoria-metrics-operator` |
| OpenTelemetry Collector (Kubernetes distribution) | The OpenTelemetry project | Helm chart `open-telemetry/opentelemetry-collector` |
| Ubuntu base image | Canonical | Container image used by the kernel-log DaemonSet |

The values files in `values/` configure these charts; they are not modified
copies of them, and the charts are fetched from their upstream repositories at
install time rather than vendored here.

Consult each project for its license terms and notices. Trainy makes no
representation about third-party software beyond having selected and configured
it, and it is provided to you by those projects, not by Trainy.

## Trainy components

| Component | Distributed as |
|---|---|
| `trainy-remediation` Helm chart (node health checks and remediation) | `oci://ghcr.io/trainy-ai/charts/trainy-remediation` |
| `trainy-npd`, `trainy-controller`, `trainy-remediator`, `mlxlink-exporter` images | `ghcr.io/trainy-ai/*` |

These are Trainy software, licensed under the Trainy Software License. The chart
carries its own `THIRD-PARTY-NOTICES.md` covering software it embeds.

## Telemetry

This bundle exists to send operational telemetry from your cluster to Trainy.
What is and is not collected is documented in the install guide and in the
comments of each values file. Nothing here transmits data anywhere other than
the endpoints you configure.
