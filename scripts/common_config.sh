#!/usr/bin/env sh

#--------------------------------------------------------------------------------
# Configuration with environment overrides.
# Export any of these variables before running the launcher to override defaults.
#
# REQUIRED: the following must be set (either here or via environment):
#   - tom_hostname
#   - certmanager_email
export tom_hostname=rogue_tracker.org
export certmanager_email=rstreet@lco.global
export project_id="rogue-planet-tracker"
export proj_descr="Rogue Planets TOM Demo"
export ACCOUNT_ID="01895C-AAC86F-3B14C7"
#--------------------------------------------------------------------------------

# GCP and cluster configuration
project_id=${project_id:-tom-demo-project}
zone=${zone:-"us-central1-a"}

proj_descr=${proj_descr:-"TOM Demo Project Prebake"}
cluster_name=${cluster_name:-tom-demo-cluster}
machine=${machine:-e2-standard-4}
nodes=${nodes:-1}

# Region/location and container registry
location=${location:-us-central1}
registry_host=${registry_host:-"${location}-docker.pkg.dev"}

# Image coordinates
image_name=${image_name:-tom-demo-image}
image_repo=${image_repo:-tom-demo-repo}
image_full_name=${image_full_name:-"${registry_host}/${project_id}/${image_repo}/${image_name}"}
image_tag=${image_tag:-"dev"}
image=${image:-"${image_full_name}:${image_tag}"}

# Kubernetes namespace and networking
kubernetes_namespace=${kubernetes_namespace:-tom-demo}
tom_static_ip_name=${tom_static_ip_name:-tom-static-ip}

# Let's Encrypt Environment
letsencrypt_env=${letsencrypt_env:-staging}
