#!/usr/bin/env bash
set -euo pipefail
# This is internal to the container, it does not relate to local system paths
K8S_CFG_INTERNAL=/home/nonroot/.kube/config
# This is internal to the container, it does not relate to local system paths
K8S_CFG_EXTERNAL=/home/nonroot/.kube/config-external
CLUSTER_NAME=${KIND_CLUSTER_NAME}

do_envsubst_on_file() {
  envsubst < $1 > $1-envsub
}

create_registry_secret(){
  ensure_namespace $2
  # This tests if the secret exists and if it doesnt it generates it
  # maybe a little hackish but does the trick without having to do weird bash checks
  kubectl create secret docker-registry $1 -n $2 --docker-server=${REGISTRY} --docker-username=${GITHUB_TOKEN_USER} --docker-password=${GITHUB_TOKEN} --docker-email=backstack-noop@backstack.dev --dry-run=client -o yaml | kubectl apply -f -
}

validate_providers() {
  for provider in {crossplane-contrib-provider-{helm,kubernetes},upbound-provider-{family-{aws,azure,gcp},aws-{ec2,eks,iam},azure-{containerservice,network},gcp-gke}}; do
    kubectl wait providers.pkg.crossplane.io/${provider} --for='condition=healthy' --timeout=5m
  done
}

validate_back_stack_configuration() {
  kubectl wait configuration/backstack --for='condition=healthy' --timeout=10m
}

deploy_secrets() {
  # TODO: This function needs to be re-wroked and allow for passing in what we want to create
  # or just move all of this to a kubernetes manifest mixin
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
      url: ${REQUEST_REPOSITORY}
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
      VAULT_HOST: ${VAULT_HOST}
      REPOSITORY: ${REPOSITORY}
      BACKSTAGE_HOST: ${BACKSTAGE_HOST}
EOF

  # TODO: this currently is not working, it is passing in the path and it needs to create the file from the path
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
      credentials: $(echo -n "${AWS_CREDENTIALS}" | base64 -w 0)
EOF

  kubectl apply -f - <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: gcp-secret
      namespace: crossplane-system
    data:
      credentials: $(echo -n "${GCP_CREDENTIALS}" | base64 -w 0)
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
      kind create cluster --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_INTERNAL} --config=./kind.cluster.config --wait=40s
      kind export kubeconfig --name ${CLUSTER_NAME} --kubeconfig=${K8S_CFG_EXTERNAL}
    fi
    docker network connect kind ${HOSTNAME}
    KIND_DIND_IP=$(docker inspect -f "{{ .NetworkSettings.Networks.kind.IPAddress }}" ${CLUSTER_NAME}-control-plane)
    sed -i -e "s@server: .*@server: https://${KIND_DIND_IP}:6443@" ${K8S_CFG_INTERNAL}
  # TODO: look at utilizing the aws mixin instead of doing all of this
  # TODO: if the above works, remove the awscli from the dockerfile tempalte
  elif [ "$CLUSTER_TYPE" = "eks" ]; then
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
