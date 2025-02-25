#!/usr/bin/env bash

HAS_HELM="$(type "helm" &> /dev/null && echo true || echo false)"
CURRENT_CONTEXT_NAME="$(kubectl config current-context view)"
PLATFORM="self-managed"

installMysql(){
    echo "Installing MySQL on $PLATFORM Kubernetes Cluster"
    helm install --wait mysql bitnami/mysql --version 8.6.1 \
    --namespace explorer \
    --set auth.user="test-user" \
    --set auth.password="password" \
    --set auth.rootPassword="password" \
    --set auth.database="accuknox"
}

installKubearmorPrometheusClient(){
    echo "Installing Kubearmor Metrics Exporter on $PLATFORM Kubernetes Cluster"
    kubectl apply -f https://raw.githubusercontent.com/kubearmor/kubearmor-prometheus-exporter/main/deployments/exporter-deployment.yaml
}

installLocalStorage(){
    echo "Installing Local Storage on $PLATFORM Kubernetes Cluster"
    case $PLATFORM in
        self-managed)
            kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
        ;;
        *)
            echo "Skipping..."
    esac
}

installPrometheusAndGrafana(){
    echo "Installing prometheus and grafana on $PLATFORM Kubernetes Cluster"
    kubectl apply -f https://raw.githubusercontent.com/kubearmor/kubearmor-prometheus-exporter/main/deployments/prometheus/prometheus-grafana-deployment.yaml &> /dev/null
}

installFeeder(){
    HELM_FEEDER="helm install feeder-service-cilium feeder --namespace=explorer --set image.repository=\"accuknox/test-feeder\" --set image.tag=\"latest\" "
    case $PLATFORM in
        gke)
            HELM_FEEDER="${HELM_FEEDER} --set platform=gke"
        ;;
        self-managed)
        ;;
        *)
            HELM_FEEDER="${HELM_FEEDER} --set kubearmor.enabled=false"
    esac
    eval "$HELM_FEEDER"
}

installCilium() {
    # FIXME this assumes that the project id, zone, and cluster name can't have
    # any underscores b/w them which might be a wrong assumption
	PROJECT_ID="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $2}')"
	ZONE="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $3}')"
	CLUSTER_NAME="$(echo "$CURRENT_CONTEXT_NAME" | awk -F '_' '{print $4}')"
    echo "Installing Cilium on $PLATFORM Kubernetes Cluster"
    case $PLATFORM in
        gke)
        	NATIVE_CIDR="$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID" --format 'value(clusterIpv4Cidr)')"
            helm install cilium cilium \
            --set image.repository=docker.io/accuknox/cilium-dev \
            --set image.tag=identity-soln \
            --set operator.image.repository=docker.io/accuknox/operator \
            --set operator.image.tag=identity-soln \
            --set operator.image.useDigest=false \
            --namespace kube-system \
            --set nodeinit.enabled=true \
            --set nodeinit.reconfigureKubelet=true \
            --set nodeinit.removeCbrBridge=true \
            --set cni.binPath=/home/kubernetes/bin \
            --set gke.enabled=true \
            --set ipam.mode=kubernetes  \
            --set hubble.relay.enabled=true \
            --set hubble.ui.enabled=true \
            --set nativeRoutingCIDR="$NATIVE_CIDR"\
            --set prometheus.enabled=true\
            --set operator.prometheus.enabled=true
        ;;
        
        *)
            helm install cilium cilium \
            --namespace kube-system \
            --set image.repository=docker.io/accuknox/cilium-dev \
            --set image.tag=identity-soln \
            --set operator.image.repository=docker.io/accuknox/operator \
            --set operator.image.tag=identity-soln \
            --set operator.image.useDigest=false \
            --set hubble.relay.enabled=true \
            --set prometheus.enabled=true \
            --set cgroup.autoMount.enabled=false \
            --set operator.prometheus.enabled=true
        ;;
    esac
}

installKubearmor(){
    echo "Installing Kubearmor on $PLATFORM Kubernets Cluster"
    case $PLATFORM in
        gke)
            kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/master/deployments/GKE/kubearmor.yaml
        ;;
        microk8s)
            microk8s kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/master/deployments/microk8s/kubearmor.yaml
        ;;
        self-managed)
            kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/master/deployments/docker/kubearmor.yaml
        ;;
        containerd)
            kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/master/deployments/generic/kubearmor.yaml
        ;;
        minikube)
            echo "Kubearmor cannot be installed on minikube. Skipping..."
        ;;
        kind)
            echo "Kubearmor cannot be installed on kind. Skipping..."
        ;;
        *)
            echo "Unrecognised platform: $PLATFORM"
    esac
}

installKnoxAutoPolicy(){
    echo "Installing KnoxAutoPolicy on on $PLATFORM Kubernetes Cluster"
    kubectl apply -f https://raw.githubusercontent.com/accuknox/knoxAutoPolicy-deployment/main/k8s/service.yaml --namespace explorer
    kubectl apply -f ./autoPolicy/dev-config.yaml --namespace explorer
    kubectl apply -f https://raw.githubusercontent.com/accuknox/knoxAutoPolicy-deployment/main/k8s/deployment.yaml --namespace explorer
    kubectl apply -f https://raw.githubusercontent.com/accuknox/knoxAutoPolicy-deployment/main/k8s/serviceaccount.yaml --namespace explorer
}

installSpire(){
    echo "Installing Spire on $PLATFORM Kubernetes Cluster"
    kubectl apply -f ./spire/spire.yaml
}

autoDetectEnvironment(){
    if [[ -z "$CURRENT_CONTEXT_NAME" ]]; then
        echo "no configuration has been provided"
        return
    fi
    
    echo "Autodetecting environment"
    if [[ $CURRENT_CONTEXT_NAME =~ ^minikube.* ]]; then
        PLATFORM="minikube"
        elif [[ $CURRENT_CONTEXT_NAME =~ ^gke_.* ]]; then
        PLATFORM="gke"
        elif [[ $CURRENT_CONTEXT_NAME =~ ^kind-.* ]]; then
        PLATFORM="kind"
        elif [[ $CURRENT_CONTEXT_NAME =~ ^k3d-.* ]]; then
        PLATFORM="k3d"
    fi
}

installHelm(){
    cd /tmp/ || return
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    cd - || return
}

if [[ $KUBEARMOR ]]; then
    echo "Installing KubeArmor"
fi

if [[ $HAS_HELM != "true" ]]; then
    echo "Helm not found, installing helm"
    installHelm
fi

echo "Adding helm repos"
helm repo add bitnami https://charts.bitnami.com/bitnami &> /dev/null

kubectl create ns explorer &> /dev/null

autoDetectEnvironment

installCilium
installLocalStorage
installMysql
installFeeder
installPrometheusAndGrafana

if [[ $KUBEARMOR ]]; then
    installKubearmor
    installKubearmorPrometheusClient
fi

installKnoxAutoPolicy
installSpire
