#!/usr/bin/env bash
set -euo pipefail
# This is internal to the container, it does not relate to local system paths
K8S_CFG_INTERNAL=/home/nonroot/.kube/config
# This is internal to the container, it does not relate to local system paths
K8S_CFG_EXTERNAL=/home/nonroot/.kube/config-external
CLUSTER_NAME=backstack-hub

validate_providers() {
  for provider in {crossplane-contrib-provider-{helm,kubernetes},upbound-provider-{family-{aws,azure,gcp},aws-{ec2,eks,iam},azure-{containerservice,network},gcp-gke}}; do
    kubectl wait providers.pkg.crossplane.io/${provider} --for='condition=healthy' --timeout=5m
  done
}

validate_back_stack_configuration() {
  kubectl wait configuration/backstack --for='condition=healthy' --timeout=10m
}

# deploy_backstack_hub() {
#   # this is a silly way to solve the problem of waiting for the custom CRDs to
#   # show up and be ready, but for now its an easy enough way to get around it
#   # not dropping out of the install. This is NOT a fool proof way of solving this
#   echo "Waiting for Backstack CRDs to be ready"
#   while ! kubectl get crd hubs.backstack.dev &>/dev/null; do sleep 1; done
#   # deploy hub
#   kubectl apply -f - <<-EOF
#       apiVersion: backstack.dev/v1alpha1
#       kind: Hub
#       metadata:
#         name: hub
#       spec:
#         parameters:
#           clusterId: local
#           repository: ${REPOSITORY}
#           backstage:
#             host: ${BACKSTAGE_HOST}
#             image:
#               registry: ghcr.io
#               repository: back-stack/showcase-backstage
#               tag: latest
#               pullPolicy: Always
#           argocd:
#             host: ${ARGOCD_HOST}
#           vault:
#             host: ${VAULT_HOST}
# EOF
# }

deploy_secrets() {
  ensure_namespace argocd
  kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: clusters-repository
      namespace: argocd
      labels:
        argocd.argoproj.io/secret-type: repository
    stringData:
      type: git
      url: ${REPOSITORY}
      password: ${GITHUB_TOKEN}
      username: ${GITHUB_TOKEN_USER}
EOF

  ensure_namespace backstage
  kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: backstage
      namespace: backstage
    stringData:
      GITHUB_TOKEN: ${GITHUB_TOKEN}
      VAULT_TOKEN: ${VAULT_TOKEN}
EOF

  ensure_namespace crossplane-system
  kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: azure-secret
      namespace: crossplane-system
    data:
      credentials: $(echo -n "${AZURE_CREDENTIALS}" | base64 -w 0)
EOF

  kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: aws-secret
      namespace: crossplane-system
    data:
      credentials: $(echo -n "$AWS_CREDENTIALS" | base64 -w 0)
EOF
}

ensure_namespace() {
  kubectl get namespaces -o name | grep -q $1 || kubectl create namespace $1
}

ensure_kubernetes() {
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    if $(kind get clusters | grep -q ${CLUSTER_NAME}); then
      echo KinD Cluster Exists
      kind export kubeconfig --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_INTERNAL}
      kind export kubeconfig --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_EXTERNAL}
    else
      echo Create KinD Cluster
      kind create cluster --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_INTERNAL} --config=/cnab/app/kind.cluster.config --wait=40s
      kind export kubeconfig --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_EXTERNAL}
    fi
    docker network connect kind ${HOSTNAME}
    KIND_DIND_IP=$(docker inspect -f "{{ .NetworkSettings.Networks.kind.IPAddress }}" ${CLUSTER_NAME}-control-plane)
    sed -i -e "s@server: .*@server: https://${KIND_DIND_IP}:6443@" ${K8S_CFG_INTERNAL}
  # TODO: look at utilizing the aws mixin instead of doing all of this
  # TODO: if the above works, remove the awscli from the dockerfile tempalte
  elif [ "$CLUSTER_TYPE" = "eks" ]; then
    # if [ ! -d "~/.aws" ]; then
    #   mkdir ~/.aws
    #   echo -n "$AWS_CREDENTIALS" > ~/.aws/credentials
    # fi
    # there is no difference between internal and external
    # when we are dealing with anything other than KinD
    cp ${K8S_CFG_INTERNAL} ${K8S_CFG_EXTERNAL}
    kubectl get ns >/dev/null
  else
    echo !!!====================================!!!\n
    echo !!! Your cluster type is not supported !!!\n
    echo !!! out of the box. We will attempt an !!!\n
    echo !!! install of the HUB, however, expect!!! \n
    echo !!! potential failures\n               !!!
    echo !!!====================================!!!\n
    cp ${K8S_CFG_INTERNAL} ${K8S_CFG_EXTERNAL}
    kubectl get ns >/dev/null
  fi
}

restart_pod() {
  kubectl rollout restart deployment $2 -n $1
}

return_argo_initial_pass() {
  while ! kubectl -n argocd get secret argocd-initial-admin-secret &>/dev/null; do sleep 1; done
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d >~/argo_initial_passwd
}

upgrade() {
  echo World 2.0
}

uninstall() {
  if [ "$CLUSTER_TYPE" = "kind" ]; then
    kind delete cluster --name ${CLUSTER_NAME}
    exit 0
  else
    echo !!!====================================!!!\n
    echo !!! Uninstall process will remove all  !!!\n
    echo !!! helm charts that were installed    !!!\n
    echo !!! the process will NOT delete the    !!!\n
    echo !!! namespaces. That is up to you to do!!!\n
    echo !!!====================================!!!\n
  fi
}

# Call the requested function and pass the arguments as-is
"$@"
