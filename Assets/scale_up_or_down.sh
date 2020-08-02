#!/bin/bash

function print_usage() {
  CMD="$1"
  ERROR_MSG="$2"

  if [ "$ERROR_MSG" != "" ]; then
    echo -e "\nERROR: $ERROR_MSG"
  fi

  echo -e "\nUse this script to scale a Fusion cluster down when not in use or back up when needed again"
  echo -e "\nUsage: $CMD up|down [OPTIONS] ... where OPTIONS include:\n"
  echo -e "  -c          Name of the cluster (required)\n"
  echo -e "  -p          GCP Project ID (required)\n"
  echo -e "  -r          Helm release name for installing Fusion 5, defaults to 'f5'\n"
  echo -e "  -n          Kubernetes namespace to install Fusion 5 into, defaults to 'default'\n"
  echo -e "  -z          GCP Zone the cluster is running in, defaults to 'us-west1'\n"
  echo -e "  --nodes     Number of nodes to restore; required for the 'up' action, no default."
  echo -e "                If you're running a multi-az cluster, this gives the number of nodes per zone."
  echo -e "                For zonal clusters, this is the total number of nodes in the zone\n"
  echo -e "  --replicas  Number of Solr and ZK replicas; defaults to 3"
  echo -e "                If you only have 1 node in the cluster, then change this to 1"
}

SCRIPT_CMD="$0"
GCLOUD_PROJECT=
GCLOUD_ZONE=us-west1
CLUSTER_NAME=
RELEASE=f5
NAMESPACE=default
MY_VALUES=${RELEASE}_${NAMESPACE}_fusion_values.yaml
ACTION=
NUM_NODES=""
NUM_REPLICAS=3

if [ $# -gt 0 ]; then
  while true; do
    case "$1" in
        up)
            ACTION="up"
            NUM_REPLICAS=1
            shift 1
        ;;
        down)
            ACTION="down"
            shift 1
        ;;
        -c)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -c parameter!"
              exit 1
            fi
            CLUSTER_NAME="$2"
            shift 2
        ;;
        -n)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -n parameter!"
              exit 1
            fi
            NAMESPACE="$2"
            MY_VALUES="${RELEASE}_${NAMESPACE}_fusion_values.yaml"
            shift 2
        ;;
        -p)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -p parameter!"
              exit 1
            fi
            GCLOUD_PROJECT="$2"
            shift 2
        ;;
        -r)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -r parameter!"
              exit 1
            fi
            RELEASE="$2"
            MY_VALUES="${RELEASE}_${NAMESPACE}_fusion_values.yaml"
            shift 2
        ;;
        -z)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -z parameter!"
              exit 1
            fi
            GCLOUD_ZONE="$2"
            shift 2
        ;;
        --nodes)
            NUM_NODES="$2"
            shift 2
        ;;
        --replicas)
            NUM_REPLICAS="$2"
            shift 2
        ;;
        -help|-usage)
            print_usage "$SCRIPT_CMD"
            exit 0
        ;;
        --)
            shift
            break
        ;;
        *)
            if [ "$1" != "" ]; then
              print_usage "$SCRIPT_CMD" "Unrecognized or misplaced argument: $1!"
              exit 1
            else
              break # out-of-args, stop looping
            fi
        ;;
    esac
  done
fi

if [ "$CLUSTER_NAME" == "" ]; then
  print_usage "$SCRIPT_CMD" "Please provide the GKE cluster name using: -c <cluster>"
  exit 1
fi

if [ "$GCLOUD_PROJECT" == "" ]; then
  print_usage "$SCRIPT_CMD" "Please provide the GCP project name using: -p <project>"
  exit 1
fi

if [ "$ACTION" != "up" ] && [ "$ACTION" != "down" ]; then
  print_usage "$SCRIPT_CMD" "Please specify an action! Either up or down!"
  exit 1
fi

if [ "$ACTION" == "up" ] && [ "$NUM_NODES" == "" ]; then
  print_usage "$SCRIPT_CMD" "Must specify the number of nodes to scale up to using --nodes N"
  exit 1
fi

has_gcloud=$(gcloud --version > /dev/null 2<&1)
has_prereq=$?
if [ $has_prereq == 1 ]; then
  echo -e "\nERROR: Must install GCloud command line tools! See https://cloud.google.com/sdk/docs/quickstarts"
  exit 1
fi

# verify the user is logged in ...
who_am_i=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
if [ "$who_am_i" == "" ]; then
  echo -e "\nERROR: GCloud user unknown, please use: 'gcloud auth login <account>' before proceeding with this script!"
  exit 1
fi

echo -e "\nLogged in as: $who_am_i\n"

hash kubectl
has_prereq=$?
if [ $has_prereq == 1 ]; then
  echo -e "\nERROR: Must install kubectl before proceeding with this script! For GKE, see: https://cloud.google.com/sdk/docs/"
  exit 1
fi

gcloud config set compute/zone $GCLOUD_ZONE
gcloud config set project $GCLOUD_PROJECT
gcloud container clusters get-credentials $CLUSTER_NAME
kubectl config current-context

# TODO: parse the kubectl get deployments output vs. hard-coding
declare -a deployments=("admin-ui" "api-gateway" "auth-ui" "cx-scheduler" "cx-script-executor" "cx-ui" "cx-user-prefs" "devops-ui" "fusion-admin" "fusion-indexing" "insights" "job-launcher" "job-rest-server" "ml-model-service" "query-pipeline" "rest-service" "rpc-service" "rules-ui" "sql-service-cm" "sql-service-cr" "webapps")

if [ "$ACTION" == "down" ]; then
  # scale down the deployments first, then the statefulsets
  for i in "${deployments[@]}"
  do
     next="${RELEASE}-$i"
     kubectl scale deployments/${next} --replicas=0 -n ${NAMESPACE}
  done

  declare -a stateful=("classic-rest-service" "cx-api" "kafka" "logstash" "solr")
  for i in "${stateful[@]}"
  do
     next="${RELEASE}-$i"
     kubectl scale statefulsets/${next} --replicas=0 -n ${NAMESPACE}
  done

  # do ZK last ... and wait
  kubectl scale statefulsets/${RELEASE}-zookeeper --replicas=0 -n ${NAMESPACE} --timeout=180s

  # now scale down the number of nodes
  gcloud beta container clusters resize ${CLUSTER_NAME} --node-pool default-pool --num-nodes 0

  echo -e "\nAll done! To bring the cluster back, do:\n     ./scale_up_or_down.sh up -c ${CLUSTER_NAME} -p ${GCLOUD_PROJECT} -n ${NAMESPACE} -r ${RELEASE} --nodes ${NUM_NODES}\n"
  exit 0
fi

echo -e "\nStarting up ${NUM_NODES} for cluster ${CLUSTER_NAME}\n"
gcloud beta container clusters resize ${CLUSTER_NAME} --node-pool default-pool --num-nodes 1

# bring back the statefulsets and then the deployments
echo -e "\nBringing ${NUM_REPLICAS} Zookeeper pods back up on ${NUM_NODES} nodes ... will wait up to 3 minutes to see ZK re-establish quorum"
kubectl scale statefulsets/${RELEASE}-zookeeper --replicas=${NUM_REPLICAS} -n ${NAMESPACE}
kubectl rollout status statefulset/${RELEASE}-zookeeper -n ${NAMESPACE} --timeout=180s

echo -e "\nBringing ${NUM_REPLICAS} Solr pods back up on ${NUM_NODES} nodes ... will wait up to 3 minutes to see Solr come back online"
kubectl scale statefulsets/${RELEASE}-solr --replicas=${NUM_REPLICAS} -n ${NAMESPACE}
kubectl rollout status statefulset/${RELEASE}-solr -n ${NAMESPACE} --timeout=180s

declare -a stateful=("logstash" "classic-rest-service" "cx-api" "kafka")
for i in "${stateful[@]}"
do
   next="${RELEASE}-$i"
   echo -e "\nScaling StatefulSet $next UP ..."
   kubectl scale statefulsets/${next} --replicas=1 -n ${NAMESPACE}
done

for i in "${deployments[@]}"
do
   next="${RELEASE}-$i"
   echo -e "\nScaling deployment $next UP ..."
   kubectl scale deployments/${next} --replicas=1 -n ${NAMESPACE}
done

kubectl get pods

