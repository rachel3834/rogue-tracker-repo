pushd "$(dirname "${BASH_SOURCE[0]}")"; proj_dir=`pwd`; popd

#--------------------------------------------------------------------------------
# This script is designed to be run over and over without causing harm
# to a system. Successive runs should push the system toward a good
# state and preserve that good state, whether or not the script
# fails. This design philosophy is common in devops, and scripts that
# adhere to it are called idempotent. 
#
# Idempotent scripts, in theory, should be easier to debug and
# develop, because it isn't necessary to start from a completely fresh
# state each time they are run. If you decide to run this script
# end-to-end and run into a problem, read the comments close to where
# the problem occurred. Those comments may help lead you to a
# solution. After solving one issue, you should be able to simply
# rerun the script from the beginning.
#
# To that end, these options enable some useful output and cause the
# script to fail more quickly in the event of an error. This prevents
# the script from continuing too far, allowing the user to debug the
# problem and rerun the script from the beginning.
# --------------------------------------------------------------------------------

set -o pipefail # A command composed of piped commands is considered
                # to have failed if any of its piped commands have
                # failed.

set -e          # Exit immediately if a command fails.

set -u          # When interpolating (substituting into a string) a variable,
                # if that variable is unset, the command performing the
                # substitution is considered to have failed.

set -x          # Print each command as it is being executed.

#--------------------------------------------------------------------------------
# configuration
#--------------------------------------------------------------------------------

. "${proj_dir}/common_config.sh"

# Deployment/domain configuration (REQUIRED)
tom_hostname=${tom_hostname:-}
if [ -z "$tom_hostname" ]; then
  echo "ERROR: tom_hostname is required. Set it in the environment or scripts/common_config.sh" >&2
  exit 1
fi

# cert-manager email (REQUIRED)
certmanager_email=${certmanager_email:-}
if [ -z "$certmanager_email" ]; then
  echo "ERROR: certmanager_email is required. Set it in the environment or scripts/common_config.sh" >&2
  exit 1
fi

#--------------------------------------------------------------------------------
# As described in the documentation, Helm is a tool that sits on top
# of Kubernetes. A Helm chart consists of a packaged, configurable set
# of Kubernetes manifests. Manifests define Kubernetes objects,
# sometimes in terms of other objects, and applying them to a
# Kubernetes cluster will change its state, potentially launching pods
# that host services, load balancing over them, configuring
# connectivity, or making other changes. Applying a Helm chart to a
# Kubernetes cluster results in a "release," which is effectively a
# chart running on a Kubernetes cluster.
#
# There are some helpful repositories of Helm charts available, which
# we idempotently install below. The first repository installs some
# general-purpose charts, while the second installs ingress-nginx, a
# helm chart that makes it possible to portably add TLS to the
# Kubernetes cluster.
# --------------------------------------------------------------------------------

if ! helm repo list | cut -f 1 | grep bitnami; then
    echo "OK. Bitnami repo for helm not installed. installing"
    helm repo add bitnami https://charts.bitnami.com/bitnami
fi

if ! helm repo list | cut -f 1 | grep ingress-nginx; then
    echo "OK. nginx repo for helm not installed. installing"
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
fi

#--------------------------------------------------------------------------------
# Install cert-manager (for automatic Let's Encrypt certificates)
#--------------------------------------------------------------------------------

if ! helm repo list | cut -f 1 | grep -q jetstack; then
    echo "OK. jetstack repo for helm not installed. installing"
    helm repo add jetstack https://charts.jetstack.io
fi
helm repo update

if ! kubectl get namespace cert-manager >/dev/null 2>/dev/null; then
    kubectl create namespace cert-manager
fi

helm upgrade --install cert-manager jetstack/cert-manager \
     -n cert-manager \
     --set crds.enabled=true \
     --wait

#--------------------------------------------------------------------------------
# Next, build the Docker image and push it to a Google Compute Project
# repository. A repsitory is simply a container within an artifact
# registry, which can be used for storing many different kinds of
# objects encoding computer programs, in this case a docker
# container. Other repositories include places to store Python, Java,
# and Javascript packages.
# --------------------------------------------------------------------------------

# First, configure docker to push to the registry host. This will
# modify your docker configuration, but docker commands that only
# operate on local objects, like `docker build`, will not be
# affected. This is so we can run `docker push` below and push to a
# container repository that Kubernetes pods will later use to pull
# their images from.
gcloud auth configure-docker "${registry_host}"

# Idempotently create the repository.
if ! gcloud artifacts repositories describe --location "$location" "$image_repo" >/dev/null 2>/dev/null; then
    echo Creating repo "$image_repo"
    gcloud artifacts repositories create "$image_repo" \
           --repository-format=docker \
           --location "$location" \
           --description "Tom images"
fi

# Now idempotently build and push the image.
if docker manifest inspect "$image" >/dev/null 2>/dev/null; then
    echo "OK. image exists. continuing."
else
    echo "Building docker image"
    docker build -t "$image" .
    docker push "$image"
fi

#--------------------------------------------------------------------------------
# Next, we'll create a static IP address for the demo TOM. This IP
# address is the one that an end-user will navigate to in order to
# actually access the TOM UI!
# --------------------------------------------------------------------------------

# First, idempotently create the compute address, which will create
# the static IP address. Be careful here: the region of this object
# should match the region of the Kubernetes cluster in order to ensure
# that it can be properly used by the object.
if ! gcloud compute addresses describe "$tom_static_ip_name" --region "$location"; then
    gcloud compute addresses create "$tom_static_ip_name" --region "$location"
fi
static_external_ip=$(gcloud compute addresses describe "$tom_static_ip_name" --region "$location" --format='get(address)')
echo got static external IP "$static_external_ip"

chart_dir="$(dirname "${proj_dir}")"

#--------------------------------------------------------------------------------
# Now wire up the actual ingress using the ingress-nginx from the
# ingress-nginx repository we installed above. The objects created by
# ingress-nginx can be shared among multiple Kubernetes objects. The
# nginx instance created in the tom-demo chart will use this resource
# in order to create a TLS interface to the service.
# --------------------------------------------------------------------------------

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx        \
     -n "${kubernetes_namespace}-ingress-nginx"                         \
     --create-namespace                                                 \
     --set controller.ingressClassResource.name=nginx-ingress-private   \
     --set controller.ingressClass=nginx-ingress-private                \
     --set controller.service.type=LoadBalancer                         \
     --set controller.service.externalTrafficPolicy=Local               \
     --set controller.service.loadBalancerIP="$static_external_ip"      \
     --wait

#--------------------------------------------------------------------------------
# Now install our own helm chart, which involves building it, creating
# some secrets, and finally installing it.
# --------------------------------------------------------------------------------

# Idempotently create the kubernetes namespace.
if ! kubectl get namespace "${kubernetes_namespace}" >/dev/null 2>/dev/null; then
    kubectl create namespace "${kubernetes_namespace}"
fi

# Build the chart.
helm dependency build "${chart_dir}/helm-chart"

# Create a placeholder
if ! kubectl -n "$kubernetes_namespace" get secret tom-demo-secrets 2>/dev/null >/dev/null; then
    kubectl -n "$kubernetes_namespace" create secret generic tom-demo-secrets --from-literal=placeholder=1
fi

if [[ "$letsencrypt_env" == staging ]]; then
    acme_hostname=acme-staging-v02.api
    certmanager_issuer_name=letsencrypt-staging
elif [[ "$letsencrypt_env" == prod ]]; then
    acme_hostname=acme-v02.api
    certmanager_issuer_name=letsencrypt
else 
    echo unrecognized letsyncrypt environment: "$letsencrypt_env"
fi

# Install the TOM helm chart!
helm upgrade --install demo "${chart_dir}/helm-chart"                                    \
     -n "$kubernetes_namespace"                                                          \
     --create-namespace                                                                  \
     -f helm-chart/values-dev.yaml                                                       \
     --set image.repository="$image_full_name"                                           \
     --set image.tag="$image_tag"                                                        \
     --set ingress.tls[0].secretName=tom-tls                                             \
     --set ingress.hosts[0].host="$tom_hostname"                                         \
     --set ingress.tls[0].hosts[0]="$tom_hostname"                                       \
     --set csrf_trusted_origins[0]="https://${tom_hostname}"                             \
     --set-string 'ingress.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect=true' \
     --set certManager.enabled=true                                                      \
     --set certManager.issuerKind=ClusterIssuer                                          \
     --set certManager.issuerName="$certmanager_issuer_name"                             \
     --set certManager.email="$certmanager_email"                                        \
     --set certManager.acmeServer="https://${acme_hostname}.letsencrypt.org/directory"   \
     --set certManager.http01.ingressClass=nginx-ingress-private                         \
     --wait
