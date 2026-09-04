# Trainy telemetry install

Self-serve install of the components that let Trainy see your GPU cluster's
health: metrics, infrastructure logs, Kubernetes events, and GPU node health
checks.

**Full guide, including what data does and does not leave your cluster:**
https://docs.trainy.ai/cluster-telemetry

## Quickstart

```bash
cd trainy-telemetry

cp trainy-telemetry.conf.example trainy-telemetry.conf
$EDITOR trainy-telemetry.conf     # set CUSTOMER (Trainy gives you this)

./install.sh --dry-run            # see exactly what would run
./install.sh
```

Re-running is safe and is how you upgrade or change an install. To check an
existing install without changing anything: `./install.sh --verify`. To remove
everything it installed: `./install.sh --uninstall`.

## What is here

| File | What it is |
|---|---|
| `install.sh` | The installer. Every step is `helm upgrade --install` or `kubectl apply`; `--dry-run` prints all of it, including the generated config. |
| `trainy-telemetry.conf.example` | The one file you edit. Copy to `trainy-telemetry.conf`. |
| `values/vm-operator.yaml` | VictoriaMetrics operator — converts your ServiceMonitors into scrape targets for the agent below. |
| `manifests/vmagent.yaml` | The metrics shipper itself (a VMAgent CR), plus the GPU scrape job. |
| `values/otel-logs.yaml` | Pod logs, from allowlisted infrastructure namespaces only. |
| `values/otel-events.yaml` | Kubernetes events, from allowlisted namespaces plus node events. |
| `values/node-health.yaml` | GPU node health checks (`trainy-npd`). Detection only by default. |
| `manifests/dmesg.yaml` | Kernel-log DaemonSet, one pod per node. Privileged — read the header before approving it. |

Every file is commented with what it does and why, and each carries the exact
`helm`/`kubectl` command to apply it by hand if you would rather not run the
script.

## Requirements

- `kubectl` and `helm` 3.8+, with cluster-admin on the target cluster
- A cluster identifier issued by Trainy (`CUSTOMER` in the config)
- Outbound HTTPS to the Trainy ingest endpoint, **and** your egress IP
  allowlisted by Trainy — until it is, the collectors run healthy and buffer
  locally while nothing arrives
- **Your monitoring stack already running** `kube-state-metrics`,
  `node-exporter` and a GPU metrics exporter, with ServiceMonitors for them.
  This install ships what you already collect; it installs no exporters. The
  installer reports at preflight which of these it can and cannot find.

## Licensing

Distributed under the Trainy Software License — see `LICENSE`. `NOTICE.md` lists
the third-party software the installer fetches (the VictoriaMetrics operator,
the OpenTelemetry Collector, and the base image used for kernel-log capture),
which is published by those projects under their own licenses.

## What this does not do

It installs no Prometheus, no Grafana, no exporters, and no scheduler. If you
run your own monitoring stack it is not modified, not replaced, and not scraped
through — the agent reads the same exporters your stack reads and ships a copy.
