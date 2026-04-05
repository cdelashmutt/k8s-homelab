# k8s-homelab Project Notes

Guidelines and hard-won lessons for working on this repo.

## Stack Overview

- **k3s** on 3 Ubuntu nodes (ubuntu1/2/3), managed by Ansible
- **kapp-controller** (Carvel) for GitOps — Apps in `bootstrap` namespace pull from this repo
- **SOPS + age** for secret encryption (`clusters/bare-metal/values/secret-values.sops.yaml`)
- **ytt** for templating, **helm** charts fetched and templated by kapp-controller
- **Longhorn** for persistent storage (RWO + RWX via NFS share-manager)
- **Traefik** ingress, **kube-vip** for VIP/load-balancer

## Helm Values Pattern

**Always use `valuesFrom:` + ConfigMap (or Secret), never inline `values:`.**

Inline `helmTemplate.values` is unreliable in kapp-controller — values are silently ignored by the chart. Every helm-based App must follow this pattern:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-values
  namespace: bootstrap
  annotations:
    kapp.k14s.io/change-group: myapp-values
data:
  values.yaml: |
    key: value
---
apiVersion: kappctrl.k14s.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: bootstrap
  annotations:
    kapp.k14s.io/change-group: myapp
    kapp.k14s.io/change-rule: "upsert after upserting myapp-values"
spec:
  template:
  - helmTemplate:
      namespace: myapp-namespace
      valuesFrom:
      - configMapRef:
          name: myapp-values
```

For secret values, use a Secret + `secretRef:` instead. See `monitoring/values-secret.yaml` and `harbor/values-secret.yaml` for examples using ytt data value templating (`#@ load("@ytt:data", "data")`).

## ServiceMonitor Label Requirement

Prometheus is configured with `serviceMonitorSelector: matchLabels: release: monitoring`. Any ServiceMonitor not carrying that label will be silently ignored.

- For manually-created ServiceMonitors (inline in app.yaml ytt), add `labels: release: monitoring` to the metadata.
- For chart-generated ServiceMonitors, use the chart's `additionalLabels` value (e.g. Longhorn: `metrics.serviceMonitor.additionalLabels: {release: monitoring}`).

## kapp Label Scoping

kapp-controller injects its `kapp.k14s.io/app` tracking label into Service `spec.selector`. This breaks Services whose pods are created by an operator (e.g. prometheus-operator) rather than kapp itself — the selector never matches, leaving the Service with no endpoints.

Fix: add a ytt overlay annotating the affected Service with `kapp.k14s.io/disable-label-scoping: ""`. See `monitoring/app.yaml` for the pattern.

## k3s-Specific Prometheus Alerts

Disable these in kube-prometheus-stack values — k3s bundles these components internally and doesn't expose the standard scrape endpoints:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
```

## Safe k3s Node Restart

Never `systemctl restart k3s` directly — it corrupts iptables and leaves stale pod network namespaces. The Ansible `install-k3s.yaml` playbook has a `Restart k3s` handler that does cordon → drain → restart → wait Ready → uncordon → recycle Longhorn CSI plugin pod.

## Longhorn

- Drain requires `--disable-eviction` to bypass instance-manager PodDisruptionBudgets
- After k3s restart, the Longhorn CSI plugin DaemonSet pod must be deleted and recreated (it survives drain with a stale network namespace)
- RWX volumes are served by a share-manager pod that won't start if the volume's replica is still rebuilding (2-minute retry backoff)

## kube-vip

- kube-vip runs as a DaemonSet (hostNetwork: true) and manages the control-plane VIP
- k3s addon controller manages `/var/lib/rancher/k3s/server/manifests/kube-vip.yaml` but reconciles unreliably at runtime — the Ansible handler does a direct `kubectl apply` when the manifest changes
- flannel reads node IPs from NIC addresses; without `node-ip` set in k3s config, flannel picks up the kube-vip VIP as the node's public IP, causing VxLAN misrouting

## Secrets / SOPS

- Age key is at `~/.config/sops/age/keys.txt` (not committed)
- Ansible vault password is at `~/.ansible/vault_pass` (not committed)
- To add a new secret: `sops clusters/bare-metal/values/secret-values.sops.yaml`
- Non-secret values: `clusters/bare-metal/values/non-secret-values.yaml`
