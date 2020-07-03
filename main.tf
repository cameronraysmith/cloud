# ---------------------------------------------------------------------------------------------------------------------
# DEPLOY A GKE PRIVATE CLUSTER IN GOOGLE CLOUD PLATFORM
# This is an example of how to use the gke-cluster module to deploy a private Kubernetes cluster in GCP.
# Load Balancer in front of it.
# ---------------------------------------------------------------------------------------------------------------------

terraform {
  # The modules used in this example have been updated with 0.12 syntax, additionally we depend on a bug fixed in
  # version 0.12.7.
  required_version = ">= 0.12.7"
}

# ---------------------------------------------------------------------------------------------------------------------
# PREPARE PROVIDERS
# ---------------------------------------------------------------------------------------------------------------------

provider "google" {
  version = "~> 3.1.0"
  project = var.project
  region  = var.region

  scopes = [
    # Default scopes
    "https://www.googleapis.com/auth/compute",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/ndev.clouddns.readwrite",
    "https://www.googleapis.com/auth/devstorage.full_control",

    # Required for google_client_openid_userinfo
    "https://www.googleapis.com/auth/userinfo.email",
  ]
}

provider "google-beta" {
  version = "~> 3.1.0"
  project = var.project
  region  = var.region

  scopes = [
    # Default scopes
    "https://www.googleapis.com/auth/compute",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/ndev.clouddns.readwrite",
    "https://www.googleapis.com/auth/devstorage.full_control",

    # Required for google_client_openid_userinfo
    "https://www.googleapis.com/auth/userinfo.email",
  ]
}

# We use this data provider to expose an access token for communicating with the GKE cluster.
data "google_client_config" "client" {}

# Use this datasource to access the Terraform account's email for Kubernetes permissions.
data "google_client_openid_userinfo" "terraform_user" {}

provider "kubernetes" {
  version = "~> 1.7.0"

  load_config_file       = false
  host                   = data.template_file.gke_host_endpoint.rendered
  token                  = data.template_file.access_token.rendered
  cluster_ca_certificate = data.template_file.cluster_ca_certificate.rendered
}

provider "helm" {
  # Use provider with Helm 3.x support
  version = "~> 1.1.1"

  kubernetes {
    host                   = data.template_file.gke_host_endpoint.rendered
    token                  = data.template_file.access_token.rendered
    cluster_ca_certificate = data.template_file.cluster_ca_certificate.rendered
    load_config_file       = false
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# DEPLOY A PRIVATE CLUSTER IN GOOGLE CLOUD PLATFORM
# ---------------------------------------------------------------------------------------------------------------------

module "gke_cluster" {
  # When using these modules in your own templates, you will need to use a Git URL with a ref attribute that pins you
  # to a specific version of the modules, such as the following example:
  # source = "github.com/gruntwork-io/terraform-google-gke.git//modules/gke-cluster?ref=v0.2.0"
  source = "./modules/gke-cluster"

  name = var.cluster_name

  project  = var.project
  location = var.location
  network  = module.vpc_network.network

  # Deploy the cluster in the 'private' subnetwork, outbound internet access will be provided by NAT
  # See the network access tier table for full details:
  # https://github.com/gruntwork-io/terraform-google-network/tree/master/modules/vpc-network#access-tier
  subnetwork = module.vpc_network.private_subnetwork

  # When creating a private cluster, the 'master_ipv4_cidr_block' has to be defined and the size must be /28
  master_ipv4_cidr_block = var.master_ipv4_cidr_block

  # This setting will make the cluster private
  enable_private_nodes = "true"

  # To make testing easier, we keep the public endpoint available. In production, we highly recommend restricting access to only within the network boundary, requiring your users to use a bastion host or VPN.
  disable_public_endpoint = "false"

  # With a private cluster, it is highly recommended to restrict access to the cluster master
  # However, for testing purposes we will allow all inbound traffic.
  master_authorized_networks_config = [
    {
      cidr_blocks = [
        {
          cidr_block   = "0.0.0.0/0"
          display_name = "all-for-testing"
        },
      ]
    },
  ]

  cluster_secondary_range_name = module.vpc_network.private_subnetwork_secondary_range_name
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A NODE POOL
# ---------------------------------------------------------------------------------------------------------------------

resource "google_container_node_pool" "node_pool" {
  provider = google-beta

  name     = "main-pool"
  project  = var.project
  location = var.location
  cluster  = module.gke_cluster.name

  initial_node_count = "3"

  autoscaling {
    min_node_count = "1"
    max_node_count = "10"
  }

  management {
    auto_repair  = "true"
    auto_upgrade = "true"
  }

  upgrade_settings {
    max_surge = "9"
    max_unavailable = "9"
  }

  node_config {
    image_type   = "COS"
    machine_type = "n1-standard-1"

    labels = {
      all-pools-example = "true"
    }

    # Add a private tag to the instances. See the network access tier table for full details:
    # https://github.com/gruntwork-io/terraform-google-network/tree/master/modules/vpc-network#access-tier
    tags = [
      module.vpc_network.private,
      "helm-example",
    ]

    disk_size_gb = "30"
    disk_type    = "pd-standard"
    preemptible  = true

    service_account = module.gke_service_account.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A CUSTOM SERVICE ACCOUNT TO USE WITH THE GKE CLUSTER
# ---------------------------------------------------------------------------------------------------------------------

module "gke_service_account" {
  # When using these modules in your own templates, you will need to use a Git URL with a ref attribute that pins you
  # to a specific version of the modules, such as the following example:
  # source = "github.com/gruntwork-io/terraform-google-gke.git//modules/gke-service-account?ref=v0.2.0"
  source = "./modules/gke-service-account"

  name        = var.cluster_service_account_name
  project     = var.project
  description = var.cluster_service_account_description
}

# ---------------------------------------------------------------------------------------------------------------------
# CREATE A NETWORK TO DEPLOY THE CLUSTER TO
# ---------------------------------------------------------------------------------------------------------------------

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

module "vpc_network" {
  source = "github.com/gruntwork-io/terraform-google-network.git//modules/vpc-network?ref=v0.4.0"

  name_prefix = "${var.cluster_name}-network-${random_string.suffix.result}"
  project     = var.project
  region      = var.region

  cidr_block           = var.vpc_cidr_block
  secondary_cidr_block = var.vpc_secondary_cidr_block
}

# ---------------------------------------------------------------------------------------------------------------------
# CONFIGURE KUBECTL AND RBAC ROLE PERMISSIONS
# ---------------------------------------------------------------------------------------------------------------------

# configure kubectl with the credentials of the GKE cluster
resource "null_resource" "configure_kubectl" {
  provisioner "local-exec" {
    command = "gcloud beta container clusters get-credentials ${module.gke_cluster.name} --region ${var.location} --project ${var.project}"

    # Use environment variables to allow custom kubectl config paths
    environment = {
      KUBECONFIG = var.kubectl_config_path != "" ? var.kubectl_config_path : ""
    }
  }

  depends_on = [google_container_node_pool.node_pool]
}

resource "kubernetes_cluster_role_binding" "user" {
  metadata {
    name = "admin-user"
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind      = "User"
    name      = data.google_client_openid_userinfo.terraform_user.email
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind      = "Group"
    name      = "system:masters"
    api_group = "rbac.authorization.k8s.io"
  }
}

# --------------------------------------------------------------------------------
# DEPLOY KUBERNETES APPLICATIONS (WITH KUBECTL AND HELM CHARTS)
# A chart repository is a location where packaged charts are stored and shared.
# --------------------------------------------------------------------------------
#
# This is an example installation of
# the bitnami/nginx helm chart
# 
# Define Bitnami Helm repository location,
# install the nginx chart.
# https://hub.helm.sh/charts/bitnami/nginx
#
# resource "helm_release" "nginx" {
#   depends_on = [google_container_node_pool.node_pool]

#   repository = "https://charts.bitnami.com/bitnami"
#   name       = "nginx"
#   chart      = "nginx"
# }


# This would be used if you would 
# like to create a separate namespace
# for installation of the jupyterhub
# Helm chart but it is not 
# currently utilized
# 
# Define jupyterhub helm release and
# jupyterhub Helm repository location,
# so Helm can install the jupyterhub chart to jhub.

# resource "kubernetes_namespace" "jhub" {
#   metadata {
#     name = "jhub"
#   }
# }

resource "helm_release" "jupyterhub" {
  depends_on = [google_container_node_pool.node_pool]

  repository = "https://jupyterhub.github.io/helm-chart/"
  name       = "jhub"
  namespace  = "default"
  chart      = "jupyterhub"
  version    = "0.9.0"
  timeout    = 1000
  values = [
    "${file("etc/jupyterhub.yaml")}"
  ]
}

# external-dns
# https://medium.com/@marekbartik/google-kubernetes-engine-with-external-dns-on-cloudflare-provider-24beb2a6b8fc
# Define Bitnami Helm repository location,
# install the external-dns chart.
# https://hub.helm.sh/charts/bitnami/external-dns
# "${yamldecode(file("test.yml"))}"
# "${yamldecode(file("external-dns.yaml))}"
#
# check the logs of the external-dns pod
# `kubectl get all --all-namespaces
# `kubectl logs <external-dns-cloudflare-randomstring>`

resource "helm_release" "external_dns" {
  depends_on = [google_container_node_pool.node_pool]

  repository = "https://charts.bitnami.com/bitnami"
  name       = "external-dns-cloudflare"
  chart      = "external-dns"
  version    = "3.2.3"

  values = [
    "${file("etc/external-dns.yaml")}"
  ]

}

# nginx-ingress
# Define Helm hub as repository location,
# install the nginx-ingress chart.
# https://hub.helm.sh/charts/stable/nginx-ingress
# previously utilized 
# repository = "https://kubernetes-charts.storage.googleapis.com/"
# version    = "1.40.2"
# https://github.com/jetstack/cert-manager/issues/2715#issuecomment-602285416
resource "helm_release" "nginx_ingress" {
  depends_on = [google_container_node_pool.node_pool]
  
  repository = "https://charts.bitnami.com/bitnami"
  name       = "nginx-ingress"
  chart      = "nginx-ingress-controller"
  version    = "5.3.24"
  values = [
    "${file("etc/nginx-ingress.yaml")}"
  ]
}


# cert-manager 
# install the jetstack cert-manager
# https://cert-manager.io/docs/installation/kubernetes/#installing-with-regular-manifests
# see scratch files for alternatives using
# helm https://hub.helm.sh/charts/jetstack/cert-manager
#
#
# https://github.com/jetstack/terraform-google-gke-cluster/issues/37#issue-462949901
# 
# note that:
# 
#     cert-manager-0.15.2.yaml
# 
# has been patched according to the following
#
# $ wget https://github.com/jetstack/cert-manager/releases/download/v0.15.2/cert-manager.yaml
# (with updated version)
# see https://cert-manager.io/docs/usage/ingress/#optional-configuration
# 
# add:
#  
#       - --default-issuer-name=letsencrypt-prod
#       - --default-issuer-kind=ClusterIssuer
#       - --default-issuer-group=cert-manager.io
# 
# to the # Source: cert-manager/templates/deployment.yaml section of 
# the downloaded cert-manager.yaml which has the container arguments
# 
# If the certificate acquisiton process seems to be stalled
# check `kubectl describe challenges`
# If the request is stale, you can refresh it by checking the order number
# `kubectl get orders --all-namespaces` and deleting the relevant
# certificate order `kubectl delete order <NAME OF ORDER FROM GET ORDERS>`
# ---https://github.com/jetstack/cert-manager/issues/294#issuecomment-518375550
#
resource "null_resource" "cert_manager" {

  provisioner "local-exec" {
    when    = create
    command = "kubectl apply -f etc/cert-manager-0.15.2.yaml -f etc/cluster-issuer.yaml"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete -f etc/cert-manager-0.15.2.yaml -f etc/cluster-issuer.yaml"
  }
}


#-------------------------------------------------------------------------------
# WORKAROUNDS
#-------------------------------------------------------------------------------

# This is a workaround for the Kubernetes and Helm providers as Terraform doesn't currently support passing in module
# outputs to providers directly.
data "template_file" "gke_host_endpoint" {
  template = module.gke_cluster.endpoint
}

data "template_file" "access_token" {
  template = data.google_client_config.client.access_token
}

data "template_file" "cluster_ca_certificate" {
  template = module.gke_cluster.cluster_ca_certificate
}
