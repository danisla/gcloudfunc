function gcloud-ssh() {
	local pattern=${1:-.*}
  shift 1
  local instance
  local instances
  IFS=';' read -ra instances <<< "$(gcloud compute instances list --filter=name~${pattern} --format='csv[no-heading](name)' | sort | tr '\n' ';')"
	[[ ${#instances[@]} -eq 0 ]] && echo "ERROR: No instance found matching: ${pattern}" && return 1

	if [[ ${#instances[@]} -eq 1 ]]; then
    instance=${instances[0]}
  else
	  local count=1
		echo "Multiple instances matched:"
		for i in ${instances[@]}; do 
      echo "  $count) $i"
      ((count=count+1))
    done
    local sel=0
    while [[ $sel -lt 1 || $sel -ge $count ]]; do
      read -p "Selection: " sel
    done
    instance=${instances[(sel-1)]}
	fi
  read -p "Use Bastion Host (y/N)? " bastion_input
  if [[ "${bastion_input,,}" == "y" ]]; then
    # TODO: List all instances with an external IP.
    IFS=';' read -ra instances <<< "$(gcloud compute instances list --format='csv[no-heading](name)' | sort | tr '\n' ';')"
    [[ ${#instances[@]} -eq 0 ]] && echo "ERROR: No bastion instances with external IPs found." && return 1
    local count=1
		echo "Instances with external IPs:"
		for i in ${instances[@]}; do 
      echo "  $count) $i"
      ((count=count+1))
    done
    local sel=0
    while [[ $sel -lt 1 || $sel -ge $count ]]; do
      read -p "Select bastion instance: " sel
    done
    bastion=${instances[(sel-1)]}
    gcloud compute ssh $(gcloud compute instances list --filter=name~${bastion} --uri) --ssh-flag="-A" -- \
      ssh -o StrictHostKeyChecking=no ${instance} $@
  else
    gcloud compute ssh $(gcloud compute instances list --filter=name~${instance} --uri) $@
  fi
}

function gke-credentials() {
  IFS=';' read -ra clusters <<< "$(gcloud container clusters list --uri | sort -k9 -t/ | tr '\n' ';')"
  local count=1
  for i in ${clusters[@]}; do
    IFS="/" read -ra TOKS <<< "${i}"
    echo "  $count) ${TOKS[-1]} (${TOKS[-3]})"
    ((count=count+1))
  done
  local sel=0
  while [[ $sel -lt 1 || $sel -ge $count ]]; do
    read -p "Select a GKE cluster: " sel
  done
  cluster=${clusters[(sel-1)]}
  if [[ "${cluster}" =~ zones ]]; then
    gcloud container clusters get-credentials ${cluster}
  else
    export CLOUDSDK_CONTAINER_USE_V1_API_CLIENT=false
    IFS="/" read -ra TOKS <<< "${cluster}"
    REGION=${TOKS[-3]}
    CLUSTER_NAME=${TOKS[-1]}
    gcloud beta container clusters get-credentials ${CLUSTER_NAME} --region ${REGION}
  fi
}

function gke-nat-gateway() {
  IFS=';' read -ra clusters <<< "$(gcloud container clusters list --uri | sort -k9 -t/ | tr '\n' ';')"
  local count=1
  for i in ${clusters[@]}; do
    IFS="/" read -ra TOKS <<< "${i}"
    echo "  $count) ${TOKS[-1]} (${TOKS[-3]})"
    ((count=count+1))
  done
  local sel=0
  while [[ $sel -lt 1 || $sel -ge $count ]]; do
    read -p "Select a GKE cluster: " sel
  done
  cluster=${clusters[(sel-1)]}
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