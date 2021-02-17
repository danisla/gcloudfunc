export CYAN='\033[1;36m'
export GREEN='\033[1;32m'
export RED='\033[1;31m'
export NC='\033[0m' # No Color
function log_cyan() { echo -e "${CYAN}$@${NC}"; }
function log_green() { echo -e "${GREEN}$@${NC}"; }
function log_red() { echo -e "${RED}$@${NC}"; }

function _prompt_project_id() {
  local default=$(gcloud config get-value project 2>/dev/null)
  [[ -z "${default}" ]] && default="none"
  read -p "Enter Project ID ($default)): " project_id >&2
  if [[ -z "${project_id}" ]]; then
    echo "$default"
  else
    echo "$project_id"
  fi
}

function _gke_select_cluster() {
  IFS=';' read -ra clusters <<< "$(gcloud container clusters list --uri $@ | sort -k9 -t/ | tr '\n' ';')"
  local count=1
  for i in ${clusters[@]}; do
    IFS="/" read -ra TOKS <<< "${i}"
    echo "  $count) ${TOKS[-1]} (${TOKS[-3]})" >&2
    ((count=count+1))
  done
  local sel=0
  while [[ $sel -lt 1 || $sel -ge $count ]]; do
    read -p "Select a GKE cluster: " sel >&2
  done
  echo "${clusters[(sel-1)]}"
}

function _gcp-orgs() {
	gcloud organizations list --format json
}

function _gcp-billing() {
	gcloud beta billing accounts list --format json
}

function _gcp-project-inputs() {
  ORGS_JSON=$(_gcp-orgs)
  BILLING_JSON=$(_gcp-billing)

	DEFAULT_PROJECT="${USER}-demo-$(openssl rand -hex 2)"
	read -p "Enter project ID (default: ${DEFAULT_PROJECT}): " PROJECT_ID

	PROJECT_ID=${PROJECT_ID:-${DEFAULT_PROJECT}}
	jq -r 'to_entries[] | "  \(.key+1): \(.value.displayName)  \(.value.name|split("/")|.[1])"' <<< ${ORGS_JSON} 1>&2

	read -p "Select organziation (default: 1): " ORG_NUM
	ORG_NUM=${ORG_NUM:-"1"}
	
    jq -r 'to_entries[] | "  \(.key+1): \(.value.displayName)  \(.value.name|split("/")[1])"' <<< ${BILLING_JSON} 1>&2
	read -p "Select billing account (default: 1): " BILLING_ACCOUNT_NUM
	BILLING_ACCOUNT_NUM=${BILLING_ACCOUNT_NUM:-"1"}

	ORG_ID=$(jq -r ".[${ORG_NUM}-1] | .name|split(\"/\")[1]" <<< ${ORGS_JSON})
	BILLING_ACCOUNT=$(jq -r ".[${BILLING_ACCOUNT_NUM}-1] | .name|split(\"/\")[1]" <<< ${BILLING_JSON})

	jq -r --arg project_id "${PROJECT_ID}" --arg org_id "${ORG_ID}" --arg billing_account "${BILLING_ACCOUNT}" \
	  '{"PROJECT_ID": $project_id, "ORG_ID": $org_id, "BILLING_ACCOUNT": $billing_account}' <<< "{}"
}

function gcloud-make-project() {
  PROJECT_JSON=$(_gcp-project-inputs)
  eval $(jq -r 'to_entries[]| "export \(.key)=\(.value)"' <<< "${PROJECT_JSON}")

  mkdir -p "${PROJECT_ID}"
  cd "${PROJECT_ID}"

  cat > main.tf <<EOF
provider google {
}

resource "google_project" "demo" {
  name            = "${PROJECT_ID}"
  project_id      = "${PROJECT_ID}"
  org_id          = "${ORG_ID}"
  billing_account = "${BILLING_ACCOUNT}"
}

resource "google_project_service" "cloudresourcemanager" {
  project = "\${google_project.demo.project_id}"
  service = "cloudresourcemanager.googleapis.com"
}

resource "google_project_service" "cloudbilling" {
  project            = "\${google_project.demo.project_id}"
  service            = "cloudbilling.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project            = "\${google_project.demo.project_id}"
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = "\${google_project.demo.project_id}"
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container" {
  project            = "\${google_project.demo.project_id}"
  service            = "container.googleapis.com"
  disable_on_destroy = false
}
EOF
  terraform init
  terraform apply
}

function gcloud-ssh() {
  local instance
  local instances
  local project_id=""
  local ssh_args=""

  while (( "$#" )); do
    case ${1,,} in
        "-h")
            log_cyan "USAGE: gcloud-ssh [-p <project>] [-iap]" >&2
            return 1
            ;;
        "-p")
            shift
            project_id=$1
            ;;
        "-iap")
            ssh_args="${ssh_args} --tunnel-through-iap"
            ;;
        *) log_red "ERROR: Invalid argument '$1'" && return 1 ;;
    esac
    shift
  done

  if [[ -z "${project_id}" ]]; then
      log_cyan "INFO: Fetching project ID"
      project_id=$(gcloud config get-value project 2>/dev/null)
      [[ -z "${project_id}" ]] && log_red "ERROR: no project set" && return 1
      log_cyan "INFO: using project: ${project_id}"
  fi

  export GCLOUD="gcloud --project ${project_id}"

  IFS=';' read -ra instances <<< "$(${GCLOUD} compute instances list --format='csv[no-heading](name)' | sort | tr '\n' ';')"
  [[ ${#instances[@]} -eq 0 ]] && echo "ERROR: No instances found" && return 1

  local count=1
  echo "Instances found:"
  for i in ${instances[@]}; do 
    echo "  $count) $i"
    ((count=count+1))
  done
  local sel=0
  while [[ $sel -lt 1 || $sel -ge $count ]]; do
    read -p "Selection: " sel
  done
  instance=${instances[(sel-1)]}

  read -p "Use Bastion Host (y/N)? " bastion_input
  if [[ "${bastion_input,,}" == "y" ]]; then
    local sel=0
    while [[ $sel -lt 1 || $sel -ge $count ]]; do
      read -p "Bastion selection: " sel
    done
    bastion=${instances[(sel-1)]}
    eval `ssh-agent`
    ssh-add ~/.ssh/google_compute_engine
    ${GCLOUD} compute ssh ${ssh_args} $(${GCLOUD} compute instances list --filter=name=${bastion} --uri) --ssh-flag="-A" -- \
      ssh -o StrictHostKeyChecking=no ${instance}
  else
    ${GCLOUD} compute ssh ${ssh_args} $(${GCLOUD} compute instances list --filter=name=${instance} --uri)
  fi
}

function gke-credentials() {
  [[ $@ =~ -p ]] && project_id=$(_prompt_project_id)
  [[ -z "${project_id}" ]] && project_id=$(gcloud config get-value project 2>/dev/null)
  echo "Project ID: $project_id" >&2
  cluster=$(_gke_select_cluster --project $project_id)
  IFS="/" read -ra TOKS <<< "${cluster}"
  LOCATION=${TOKS[-3]}
  CLUSTER_NAME=${TOKS[-1]}
  if [[ "${cluster}" =~ zones ]]; then
    gcloud --project ${project_id} container clusters get-credentials ${cluster} --zone ${LOCATION} ${gcloud_args}
  else
    export CLOUDSDK_CONTAINER_USE_V1_API_CLIENT=false
    gcloud --project ${project_id} beta container clusters get-credentials ${CLUSTER_NAME} --region ${LOCATION} ${gcloud_args}
  fi
}

function gke-nat-gateway() {
  cluster=$(_gke_select_cluster)
  IFS="/" read -ra TOKS <<< "${cluster}"
  PROJECT=${TOKS[-5]}
  CLUSTER_NAME=${TOKS[-1]}
  ZONE=${TOKS[-3]}
  REGION="${ZONE}"
  KIND=${TOKS[-4]}
  [[ "${KIND}" == "zones" ]] && REGION="${ZONE%-*}"
  # default to zone b in any region
  [[ "${KIND}" == "locations" ]] && ZONE="${REGION}-b"

  echo "Creating NAT gateway for cluster: ${CLUSTER_NAME} (${ZONE})..."
  
  NODE_TAG=$(gcloud compute instance-templates describe $(gcloud compute instance-templates list --filter=name~gke-${CLUSTER_NAME} --limit=1 --uri) --format='get(properties.tags.items[0])')
  MASTER_IP=$(gcloud compute firewall-rules describe ${NODE_TAG/-node/-ssh} --format='value(sourceRanges)' 2>/dev/null)
  CONFIG_DIR="${HOME}/.gke_nat_gw_${CLUSTER_NAME}_${ZONE}"
  mkdir -p ${CONFIG_DIR}
  cat > ${CONFIG_DIR}/main.tf <<'EOF'
variable gke_master_ip {
  description = "The IP address of the GKE master or a semicolon separated string of multiple IPs"
}

variable gke_node_tag {
  description = "The network tag for the gke nodes"
}

variable region {
  default = "us-central1"
}

variable zone {
  default = "us-central1-f"
}

variable network {
  default = "default"
}

provider google {
  region = "${var.region}"
}

module "nat" {
  source  = "github.com/GoogleCloudPlatform/terraform-google-nat-gateway"
  region  = "${var.region}"
  zone    = "${var.zone}"
  tags    = ["${var.gke_node_tag}"]
  network = "${var.network}"
}

// Route so that traffic to the master goes through the default gateway.
// This fixes things like kubectl exec and logs
resource "google_compute_route" "gke-master-default-gw" {
  count            = "${var.gke_master_ip == "" ? 0 : length(split(";", var.gke_master_ip))}"
  name             = "gke-master-default-gw-${count.index + 1}"
  dest_range       = "${element(split(";", replace(var.gke_master_ip, "/32", "")), count.index)}"
  network          = "${var.network}"
  next_hop_gateway = "default-internet-gateway"
  tags             = ["${var.gke_node_tag}"]
  priority         = 700
}

output "ip-nat-gateway" {
  value = "${module.nat.external_ip}"
}
EOF
  cat > ${CONFIG_DIR}/terraform.tfvars <<EOF
region = "${REGION}"
zone   = "${ZONE}"
gke_master_ip = "${MASTER_IP}"
gke_node_tag = "${NODE_TAG}"
EOF

  echo "Generated Terraform config in: ${CONFIG_DIR}"
  (export GOOGLE_PROJECT=${PROJECT} && cd ${CONFIG_DIR} && terraform init && terraform apply)
}

function gke-fix-scopes() {
  cluster=$(_gke_select_cluster)
  IFS="/" read -ra TOKS <<< "${cluster}"
  CLUSTER_NAME=${TOKS[-1]}
  if [[ "${cluster}" =~ zones ]]; then
    CLUSTER_JSON=$(gcloud container clusters describe ${cluster} --format=json)
    # Create new node pool of same machine type with --scopes=cloud-platform
    # gcloud container node-pools create cloud-platform \
    #   --cluster=${CLUSTER_NAME} \
    #   --machine-type=${MACHINE_TYPE} \
    #   --num-nodes=${NUM_NODES} \
    #   --zone=${ZONE} \
    #   --scopes=cloud-platform
    
    # # Delete the default node pool
    # gcloud container node-pools delete default-pool \
    #   --cluster=${CLUSTER_NAME} \
    #   --zone=${ZONE}
  else
    export CLOUDSDK_CONTAINER_USE_V1_API_CLIENT=false
    REGION=${TOKS[-3]}
    CLUSTER_JSON=$(gcloud beta container clusters describe ${CLUSTER_NAME} --region ${REGION} --format=json)
  fi

  echo $CLUSTER_JSON
}

function gcloud-sshfs() {
  local instance
  local instances
  IFS=';' read -ra instances <<< "$(gcloud compute instances list ${GCLOUD_ARGS} --format='csv[no-heading](name)' | sort | tr '\n' ';')"
	[[ ${#instances[@]} -eq 0 ]] && echo "ERROR: No instances found" && return 1

  local count=1
  echo "Instances found:"
  for i in ${instances[@]}; do 
    echo "  $count) $i"
    ((count=count+1))
  done
  local sel=0
  while [[ $sel -lt 1 || $sel -ge $count ]]; do
    read -p "Selection: " sel
  done
  instance=${instances[(sel-1)]}
  
  ip=$(gcloud compute instances list ${GCLOUD_ARGS} --filter=name=${instance} --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

  TARGET_MOUNT=$(id -u -n)@${ip}:/
  MOUNT_DIR=/mnt/${instance}
  sudo mkdir -p ${MOUNT_DIR}

  eval sudo sshfs \
    -o IdentityFile=${HOME}/.ssh/google_compute_engine,allow_other,default_permissions,auto_cache,reconnect,uid=$(id -u),gid=$(id -g) \
    ${TARGET_MOUNT} ${MOUNT_DIR}
  [[ $? -eq 0 ]] && echo "INFO: Mounted ${TARGET_MOUNT} to ${MOUNT_DIR}"
}

function gcloud-setup-git-hook() {
  hookfile=`git rev-parse --git-dir`/hooks/commit-msg
  mkdir -p $(dirname $hookfile) 
  curl -Lo $hookfile \
    https://gerrit-review.googlesource.com/tools/hooks/commit-msg
  chmod +x $hookfile
  unset hookfile
}

function gcr-list-tags() {
  REPO=${1/gcr.io\/}
  if [[ -z "${REPO}" ]]; then
    echo "USAGE: gcr-list-tags <repo name>"
    return 1
  fi
  TOKEN=$(gcloud auth print-access-token)
  curl -s -XGET \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" \
       "https://gcr.io/v2/${REPO}/tags/list" |
          jq -r '.tags[]' | sort --version-sort
}

function gcr-get-digest() {
  IMAGE=$1
  TAG=${IMAGE/gcr.io*:/}
  REPO_GCR=${IMAGE/:$TAG/}
  REPO=${REPO_GCR/gcr.io\//}
  if [[ -z "${REPO}" || -z "${TAG}" ]]; then
    echo "USAGE: gcr-get-digest <image:tag>"
    return 1
  fi
  TOKEN=$(gcloud auth print-access-token)
  curl -s -I \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: */*" \
    "https://gcr.io/v2/${REPO}/manifests/${TAG}" | \
    grep docker-content-digest | tr '\n' ' ' | tr '\r' ' ' | cut -d' ' -f2
}