# Kubernetes Health Check Scripts

A comprehensive collection of health check scripts for Kubernetes clusters. These scripts help diagnose issues, monitor component health, and ensure your cluster is running optimally.

## 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/gstohl/kube-help.git
cd kube-help

# Make scripts executable
chmod +x *.sh

# Run all health checks
./kube-health-check.sh --all

# Run specific checks
./kube-health-check.sh cluster nodes storage

# List available checks
./kube-health-check.sh --list
```

## 📋 Prerequisites

- `kubectl` configured with cluster access
- `jq` for JSON parsing (most scripts)
- `curl` or `wget` for API checks
- Bash 4.0 or higher

## 🔍 Available Health Checks

### Core Kubernetes Components

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-k8s-health-enhanced.sh` | Comprehensive cluster health | 12 check categories, resource analysis, recommendations |
| `check-node-health.sh` | Node health and resources | Resource usage, pod distribution, kernel analysis |
| `check-kubelet.sh` | Kubelet component health | Node conditions, pod capacity, eviction detection |
| `check-kube-proxy.sh` | Kube-proxy analysis | Mode detection (iptables/IPVS), rule verification |
| `check-etcd.sh` | etcd cluster health | Member status, performance metrics, backup checks |
| `check-coredns.sh` | CoreDNS health | DNS resolution tests, cache analysis, metrics |
| `check-metrics-server.sh` | Metrics server status | Resource metrics, HPA functionality |

### Container Runtime & Versions

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-containerd.sh` | Container runtime health | Version compatibility, image pull errors, disk pressure |
| `check-k8s-versions.sh` | Version compatibility | Component version skew, upgrade paths, deprecations |

### Security & Compliance

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-pod-security.sh` | Pod security analysis | Security context, RBAC, compliance scoring (0-100) |
| `check-certificates.sh` | Certificate health | Expiration warnings, webhook certs, TLS validation |
| `check-image-registry.sh` | Image registry health | Pull secrets, authentication, security analysis |

### Storage

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-storage-health.sh` | Persistent storage | PV/PVC analysis, CSI drivers, capacity planning |
| `check-longhorn.sh` | Longhorn storage | Volume health, replica status, disk usage |

### Networking

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-network-connectivity.sh` | Network connectivity | Live testing, MTU analysis, policy impact |
| `check-hostport-conflicts.sh` | Host port conflicts | Port collision detection, scheduling issues |
| `check-nginx-ingress.sh` | NGINX Ingress | Controller health, configuration, SSL |
| `check-cilium.sh` | Cilium CNI | Endpoint health, network policies, IPAM |
| `check-cilium-envoy.sh` | Cilium Envoy proxy | L7 policies, proxy configuration |

### Observability & Operations

| Script | Description | Key Features |
|--------|-------------|--------------|
| `check-loki.sh` | Loki logging system | Log ingestion, storage, Promtail status |
| `check-cert-manager.sh` | cert-manager | Certificate resources, ACME status, renewal |

## 🎯 Master Health Check Script

The `kube-health-check.sh` script orchestrates all health checks:

### Usage

```bash
# Run all checks
./kube-health-check.sh --all

# Run specific checks
./kube-health-check.sh cluster nodes storage security

# Save output to file
./kube-health-check.sh --all --output health-report.txt

# Run checks in parallel (experimental)
./kube-health-check.sh --all --parallel

# Verbose output
./kube-health-check.sh --all --verbose
```

### Available Check Names

- `cluster` - Enhanced cluster health
- `nodes` - Node health and resources
- `storage` - Persistent storage health
- `network` - Network connectivity test
- `security` - Pod security and compliance
- `containerd` - Container runtime health
- `versions` - Version compatibility
- `kubelet` - Kubelet health
- `kube-proxy` - Kube-proxy analysis
- `certificates` - Certificate health
- `registry` - Image registry health
- `longhorn` - Longhorn storage
- `nginx` - NGINX ingress controller
- `loki` - Loki logging system
- `cilium` - Cilium CNI
- `cilium-envoy` - Cilium Envoy proxy
- `etcd` - etcd key-value store
- `coredns` - CoreDNS
- `metrics` - Metrics server
- `cert-manager` - cert-manager
- `hostport` - Host port conflicts

## 📊 Output Format

All scripts use color-coded output for easy reading:

- 🟢 **Green** - Healthy/Success
- 🟡 **Yellow** - Warning/Attention needed
- 🔴 **Red** - Error/Critical issue
- 🔵 **Blue** - Information
- ✓ - Check passed
- ⚠ - Warning condition
- ✗ - Check failed

## 🔧 Examples

### Basic Health Check
```bash
# Quick cluster health check
./check-k8s-health-enhanced.sh
```

### Storage Troubleshooting
```bash
# Check all storage components
./kube-health-check.sh storage longhorn
```

### Security Audit
```bash
# Run security-focused checks
./kube-health-check.sh security certificates registry
```

### Network Diagnostics
```bash
# Test network connectivity
./check-network-connectivity.sh

# Check for port conflicts
./check-hostport-conflicts.sh
```

### Version Compatibility
```bash
# Check component versions
./check-k8s-versions.sh

# Check container runtime
./check-containerd.sh
```

## 🏗️ Architecture

```
kube-health-check.sh (Master Script)
├── Core Checks
│   ├── check-k8s-health-enhanced.sh
│   ├── check-node-health.sh
│   └── check-kubelet.sh
├── Network Checks
│   ├── check-network-connectivity.sh
│   ├── check-kube-proxy.sh
│   └── check-nginx-ingress.sh
├── Storage Checks
│   ├── check-storage-health.sh
│   └── check-longhorn.sh
├── Security Checks
│   ├── check-pod-security.sh
│   ├── check-certificates.sh
│   └── check-image-registry.sh
└── Component Checks
    ├── check-etcd.sh
    ├── check-coredns.sh
    └── check-metrics-server.sh
```

## 🔒 Security Considerations

- Scripts use read-only kubectl commands
- No modifications are made to cluster resources
- Network tests create temporary test pods (auto-cleaned)
- Sensitive information is not logged or exposed

## 🐛 Troubleshooting

### Script Not Found
```bash
# Ensure scripts are executable
chmod +x *.sh
```

### kubectl Not Found
```bash
# Install kubectl or ensure it's in PATH
which kubectl
```

### Permission Denied
```bash
# Ensure kubectl is configured with proper permissions
kubectl auth can-i get pods --all-namespaces
```

### JSON Parsing Errors
```bash
# Install jq
# macOS: brew install jq
# Linux: apt-get install jq / yum install jq
```

## 🤝 Contributing

Feel free to submit issues and enhancement requests!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/new-check`)
3. Commit your changes (`git commit -m 'Add new health check'`)
4. Push to the branch (`git push origin feature/new-check`)
5. Create a Pull Request

## 📝 License

This project is open source and available under the [MIT License](LICENSE).

## 🙏 Acknowledgments

- Built with assistance from [Claude](https://claude.ai)
- Inspired by Kubernetes best practices and operational experience
- Community feedback and contributions

## 📚 Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubectl Reference](https://kubernetes.io/docs/reference/kubectl/)
- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug/)

---

**Note**: These scripts are provided as-is for diagnostic purposes. Always review the output and recommendations in the context of your specific environment.