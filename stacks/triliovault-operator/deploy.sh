#!/bin/sh

set -e

################################################################################
# repo
################################################################################
helm repo add triliovault-operator http://charts.k8strilio.net/trilio-stable/k8s-triliovault-operator
helm repo update > /dev/null

################################################################################
# TVK Operator chart installation
################################################################################
STACK="triliovault-operator"
CHART="triliovault-operator/k8s-triliovault-operator"
LATEST="$(helm show chart triliovault-operator/k8s-triliovault-operator | grep appVersion | awk -F ':' '{gsub(/ /,""); print $2 }')"
echo "Installing TVK version: $LATEST"
CHART_VERSION=$LATEST
NAMESPACE="tvk"
#HOME=$ROOT_DIR
INSTALL_TVM=true
TVK_HOSTNAME="tvk.doks.com"
INGRESS_SERVICE_TYPE="NodePort"

# Install triliovault operator and triliovault manager
echo "Installing TrilioVault operator and TrilioVault Manager with one-click install functionality"

if [ -z "${MP_KUBERNETES}" ]; then
  # use local version of values.yml
  ROOT_DIR=$(git rev-parse --show-toplevel)
  values="$ROOT_DIR/stacks/triliovault-operator/values.yml"
else
  # use github hosted master version of values.yml
  values="https://raw.githubusercontent.com/digitalocean/marketplace-kubernetes/master/stacks/triliovault-operator/values.yml"
fi

helm upgrade "$STACK" "$CHART" \
  --atomic \
  --create-namespace \
  --install \
  --namespace "$NAMESPACE" \
  --values "$values" \
  --version "$CHART_VERSION" \
  --set installTVK.enabled="$INSTALL_TVM" \
  --set installTVK.ingressConfig.host="$TVK_HOSTNAME" \
  --set installTVK.ComponentConfiguration.ingressController.service.type="$INGRESS_SERVICE_TYPE"

retcode=$?
if [ "$retcode" -ne 0 ]; then
  echo "There is some error during triliovault-operator installation using helm, please contanct Trilio support"
  return 1
fi

until (kubectl get pods --namespace "$NAMESPACE" -l "release=triliovault-operator" 2>/dev/null | grep Running); do sleep 3; done

until (kubectl get pods --namespace "$NAMESPACE" -l "triliovault.trilio.io/owner=triliovault-manager" 2>/dev/null | grep Running); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l app=k8s-triliovault-exporter 2>/dev/null | grep 1/1); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l "app.kubernetes.io/name=k8s-triliovault-ingress-nginx" 2>/dev/null | grep 1/1); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l app=k8s-triliovault-web 2>/dev/null | grep 1/1); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l app=k8s-triliovault-web-backend 2>/dev/null | grep 1/1); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l app=k8s-triliovault-control-plane 2>/dev/null | grep 2/2); do sleep 3; done
until (kubectl get pods --namespace "$NAMESPACE" -l app=k8s-triliovault-admission-webhook 2>/dev/null | grep 1/1); do sleep 3; done

################################################################################
# Enable TVK Management Console using NodePort
################################################################################

access_tvk_ui () {

  echo ""
  echo "################################################################################"
  echo "TVK UI will be configured with NodePort but if you are not able to access it, please run below command to use port-forward from the machine you are accessing the TVK UI from."
  echo ""
  echo "kubectl port-forward --address 0.0.0.0 svc/k8s-triliovault-ingress-nginx-controller --namespace $NAMESPACE 80:80 &"
  echo ""
  echo "Copy & paste the above command into the terminal session and TVK management console traffic will be forwarded to your localhost IP of 127.0.0.1 via port 80."
  echo "Provide the kubeconfig file which can be downloaded from DOKS cluster UI"
  echo "################################################################################"
  echo ""

  controller=$(kubectl get pods --no-headers=true --namespace "$NAMESPACE" 2>/dev/null | awk '/k8s-triliovault-ingress-nginx-controller/{print $1}')

  if [ -z "$controller" ]; then
    echo "Not able to find k8s-triliovault-ingress-nginx-controller resource,TVK UI configuration failed"
    return 1
  fi

  node=$(kubectl get pods "$controller" --namespace "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
  ip=$(kubectl get node "$node" --namespace "$NAMESPACE" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')

  if [ -z "$ip" ]; then
    echo "ExternalIP for the node does not exists, so using InternalIP"
    ip=$(kubectl get node "$node" --namespace "$NAMESPACE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  fi

  port=$(kubectl get svc k8s-triliovault-ingress-nginx-controller --namespace "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')

  echo ""
  echo "################################################################################"
  echo "Please add '$ip $TVK_HOSTNAME' entry to your /etc/hosts file before launching the management console"
  echo "After creating an entry, TVK UI can be accessed through http://$TVK_HOSTNAME:$port/login"
  echo ""
  echo "If you still face issues while access UI, please refer - https://docs.trilio.io/kubernetes/management-console/user-interface/accessing-the-ui"
  echo "################################################################################"
}

################################################################################
# Install TVK License
################################################################################

install_license () {
  #This module is use to install license
  echo "Installing required packages.."

  pip3 install requests
  pip3 install beautifulsoup4
  pip3 install lxml

  echo "Installing Freetrial license..."

  cat <<EOF | python3
#!/usr/bin/python3

from bs4 import BeautifulSoup
import requests
import sys
import subprocess

headers = {'Content-type': 'application/x-www-form-urlencoded; charset=utf-8'}
endpoint="https://doc.trilio.io:5000/8d92edd6-514d-4acd-90f6-694cb8d83336/0061K00000i9ORf"
result = subprocess.check_output("kubectl get ns $NAMESPACE -o=jsonpath='{.metadata.uid}'", shell=True)
kubeid = result.decode("utf-8")
data = "kubescope=clusterscoped&kubeuid={0}".format(kubeid)
r = requests.post(endpoint, data=data, headers=headers)
contents=r.content
soup = BeautifulSoup(contents, 'lxml')
sys.stdout = open("tvk_do_license.yaml", "w")
print(soup.body.find('div', attrs={'class':'yaml-content'}).text)
sys.stdout.close()
result = subprocess.check_output("kubectl apply -f tvk_do_license.yaml --namespace $NAMESPACE", shell=True)
EOF

sleep 5
echo "Verifying license status on namespace $NAMESPACE ..."
lic_status=$(kubectl get license test-license-1 --namespace $NAMESPACE -o 'jsonpath={.status.status}')
exp_status="Active"

if [ "$lic_status" != "$exp_status" ] ; then
  echo "License installation failed, license status is '$lic_status'"
else
  echo "License is installed successfully, license status is '$lic_status'"
  if [ -e "tvk_do_license.yaml" ] ; then
    echo "Deleting TVK license file tvk_do_license.yaml"
    rm tvk_do_license.yaml
  else
    echo "TVK license file not found"
  fi
fi
}

################################################################################
# TVK one-click installation code starts here
################################################################################

access_tvk_ui
install_license
