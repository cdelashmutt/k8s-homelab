#!/bin/bash
set -e

function requires() {
    if ! command -v $1 &>/dev/null; then
        echo "Requires $1"
        exit 1
    fi
}

requires "ytt"
requires "kapp"
requires "kubectl"

function usage {
    echo "usage: $scriptname clustername"
    echo "  clustername  The name of the directory under clusters/ that we're using for our install"
    exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 1 ]; then
    echo "Illegal number of parameters"
    usage
fi

clustername=$1

kubectl create namespace bootstrap --dry-run=client -o yaml | kubectl apply -f-

kubectl create secret generic -n bootstrap age-secrets --from-file=key.txt=$HOME/.config/sops/age/keys.txt --dry-run=client -o yaml | kubectl apply -f-

kapp deploy -a kc -f https://github.com/carvel-dev/kapp-controller/releases/latest/download/release.yml -f- --yes << EOF
apiVersion: v1
kind: Secret
metadata:
  name: kapp-controller-config
  namespace: kapp-controller
type: Opaque
stringData:
  appDefaultSyncPeriod: 2m
  appMinimumSyncPeriod: 2m
EOF

kapp deploy -a sg -f https://github.com/carvel-dev/secretgen-controller/releases/latest/download/release.yml --yes

ytt -f bootstrap --data-value clustername=$clustername | kapp deploy -a bootstrap -f- --yes