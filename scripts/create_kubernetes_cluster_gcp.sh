# Save the directory containing this script to the $proj_dir variable.
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

# Load some configuration that is common to both scripts. 
. "${proj_dir}/common_config.sh"

#--------------------------------------------------------------------------------
# There are two new concepts here: the gcloud commandline tool, and
# google compute engine projects.
#
# You should already have installed and run the gcloud tool in the
# Google Compute Platform instructions. This is the first time we've
# created something with it. Many gcloud commands allow you to
# interact with objects in Google Compute Platform. You can generally
# "list," "describe," and "delete" objects, among other things.
#
# Here we are idempotently creating a Google Compute Platform
# project. A project is a container for many of the objects that will
# be created below. If you delete a project, it will tidily delete the
# objects within it. Projects can be used to separate different objets
# to keep things neat.
# --------------------------------------------------------------------------------

# First, check to see that the project exists. Standard input and
# standard error are both redirected to /dev/null here, meaning that
# they will not be displayed. This is to avoid the confusion of error
# messages being displayed when the project doesn't exist. It is
# expected that the project does not exist initially.
#
# Checking in this way will avoid recreating a project that already
# exists, which would otherwise result in failure, thus allowing the
# script to be rerun even after a project is successfully created.
if gcloud projects describe "$project_id" >/dev/null 2>/dev/null; then 
    # If a project already exists, there is no need to do anything.
    echo OK. project exists: "$project_id". continuing.
else
    # If a project does not exist, create it! A project requires an ID
    # and a name. The name is free-form.
    echo creating "$project_id"
    gcloud projects create "$project_id" --name="$proj_descr"
fi

# The gcloud config command configures the gcloud command itself. It
# sets the project to the potentially newly created project so that
# commands below will run by default in this project.
gcloud config set project "$project_id"

#--------------------------------------------------------------------------------
# Now retrieve the billing account. The script expects exactly one
# billing account to be created. This should be true if you've
# followed the instructions for setting up the Google Compute
# Platform. But if you haven't, you may not have a billing account. If
# you've set up more than one billing account, this will also fail.
# 
# Billing accounts can be listed, as you can see below, with the
# `gcloud billing accounts` command. You can list your billing
# accounts with the command
#
#     gcloud billing accounts list
#
# The ACCOUNT_ID column is the one we're interested in. Given project
# id $project_id and billing account $billing_account, you can
# manually link ACCOUNT_ID, you should be able to link them with this
# command, which you'll see below:
#
#     gcloud billing projects link "$project_id" --billing-account="$billing_account"
#
# After that, the test below should succeed and the script should be
# skipped on successive runs.
# --------------------------------------------------------------------------------

# First, get the billing account associated with $project_id
billing_account="$(gcloud billing projects describe "$project_id" --format="value(billingAccountName)")"

# Check to ensure that it exists, that is, that it is not empty.
if [[ -z "$billing_account" ]]; then
    echo "OK. project does not have a billing account. linking one..."

    # Get all of the billing accounts and count how many there are.
    billing_accounts="$(gcloud billing accounts list --format="value(ACCOUNT_ID)")"
    num_accounts="$(echo "$billing_accounts" | wc -w)"

    if [[ $num_accounts == 0 ]]; then
        echo A billing account must be set up first on Google Compute Engine.
        exit 1
    elif [[ $num_accounts == 1 ]]; then
        billing_account="$billing_accounts"
        echo linking "$project_id" with billing account "$billing_account"
        gcloud billing projects link "$project_id" --billing-account="$billing_account"
    else
        echo Too many billing accounts. Choose manually and rerun this script.
        gcloud billing accounts list --format="value(ACCOUNT_ID)"
        exit 1
    fi
fi

# Not all services are enabled on a newly created Google Compute
# Platform instance. You'll need to create these in order to push
# containers to Google Compute Platforma and spin up Kubernetes
# objects.
gcloud services enable container.googleapis.com compute.googleapis.com iam.googleapis.com containerregistry.googleapis.com

#--------------------------------------------------------------------------------
# Create and configure a new service account specifically for
# Kubernetes. A service account, unlike your Google Compute Platform
# user account, is designed to be run by long-running automated
# processes (services).
#
# The kubernetes service account has access to artifact storage as
# well as diagnostic and telemetry information about processes running
# within Google Compute Engine. It is used, for example, to pull
# docker images onto Kubernetes "pods," which are containers running
# in your Kubenetes environments.
# --------------------------------------------------------------------------------

# First, create the service account itself idempotently: check if it
# exists, and create it if not.
node_service_account_id=knodes
node_service_account="${node_service_account_id}@${project_id}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "${node_service_account}" >/dev/null 2>/dev/null ; then
    echo "Creating kubernetes node service account $node_service_account_id"
    gcloud iam service-accounts create "$node_service_account_id"
    sleep 10
fi


# Wait for the service account to exist. Sometimes they take a few
# minutes to create.
echo "Waiting for creation of ${node_service_account}"
for try in {1..5}; do
    # Check for the service account 
    if gcloud iam service-accounts describe "${node_service_account}" ; then
        # Found the service account. break.
        break
    else
        echo "Problem. retrying in 60 seconds. This should not fail more than one or two times."
        sleep 60
    fi
done

# Next, ensure that the service account has roles sufficient for
# spinning up Kubernetes nodes, which includes the need to read from
# an artifact registry and pull docker images from it.
for role in artifactregistry.reader logging.logWriter monitoring.metricWriter; do 
    echo ensuring role "$role"
    gcloud projects add-iam-policy-binding "$project_id" \
           --member="serviceAccount:${node_service_account}" --role="roles/${role}"
done

# Finally, create a Kubernetes cluster with a configurable nubmer of
# nodes. A single node can run multiple Kubernetes pods. Many rules
# determine which pods are assinged to which nodes, including resource
# limits and explicit selectors.
if ! gcloud container clusters describe --zone "$zone" "$cluster_name" >/dev/null 2>/dev/null; then
    echo "OK. cluster ${cluster_name} does not exist. creating it."
    gcloud container clusters create "$cluster_name"    \
           --zone "$zone"                               \
           --num-nodes="$nodes"                         \
           --service-account="${node_service_account}"  \
           --machine-type="$machine"                    \
           --enable-ip-alias
fi

# Finally, we will install the gke-gcloud-auth-plugin, and then use
# its get-credentials command to configure the kubernetes kubectl
# command to use the newly created kubernetes cluster.
gcloud components install gke-gcloud-auth-plugin
gcloud container clusters get-credentials "$cluster_name" --zone "$zone" --project "$project_id"
