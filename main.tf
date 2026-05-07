terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket   = "loitez-diploma-tfstate"
    region   = "ru-central1"
    key      = "terraform.tfstate"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    force_path_style            = true
  }
}

provider "yandex" {
  cloud_id  = "b1gojvp01s0t4gf4m1qn"
  folder_id = "b1gr6f3vahpkkk2de11c"
  zone      = "ru-central1-a"
}

resource "yandex_vpc_network" "diploma-net" {
  name = "diploma-network"
}

resource "yandex_vpc_subnet" "diploma-subnet" {
  name           = "diploma-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.diploma-net.id
  v4_cidr_blocks = ["10.1.0.0/24"]
}

resource "yandex_iam_service_account" "k8s-sa" {
  name        = "k8s-sa"
  description = "SA для управления кластером"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-clusters-agent" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "k8s.clusters.agent"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "vpc-public-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_iam_service_account" "nodes-sa" {
  name        = "nodes-sa"
  description = "SA для нод кластера"
}

resource "yandex_resourcemanager_folder_iam_member" "images-puller" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "container-registry.images.puller"
  member    = "serviceAccount:${yandex_iam_service_account.nodes-sa.id}"
}

resource "yandex_logging_group" "logging-group" {
  name      = "k8s-logs"
  folder_id = "b1gr6f3vahpkkk2de11c"
  retention_period = "72h"
}

# 4. Кластер Kubernetes
resource "yandex_kubernetes_cluster" "k8s-cluster" {
  name        = "k8s-diploma"
  network_id  = yandex_vpc_network.diploma-net.id

  master {
    zonal {
      zone      = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.diploma-subnet.id
    }
    public_ip = true

  master_logging {
        enabled      = true
        log_group_id = yandex_logging_group.logging-group.id
      }
    }

  service_account_id      = yandex_iam_service_account.k8s-sa.id
  node_service_account_id = yandex_iam_service_account.nodes-sa.id

  depends_on = [
    yandex_resourcemanager_folder_iam_member.k8s-clusters-agent,
    yandex_resourcemanager_folder_iam_member.vpc-public-admin,
    yandex_resourcemanager_folder_iam_member.k8s-logging-writer
  ]
}

resource "yandex_kubernetes_node_group" "k8s-node-group" {
  cluster_id  = yandex_kubernetes_cluster.k8s-cluster.id
  name        = "worker-nodes"

  instance_template {
    platform_id = "standard-v2"

    network_interface {
      nat                = true
      subnet_ids         = [yandex_vpc_subnet.diploma-subnet.id]
    }

    resources {
      memory = 4
      cores  = 2
    }

    boot_disk {
      type = "network-hdd"
      size = 64
    }
  }

  scale_policy {
    fixed_scale {
      size = 2
    }
  }
}

resource "yandex_container_registry" "diploma-registry" {
  name = "diploma-registry"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-lb-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "load-balancer.admin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-vpc-public-admin" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "vpc.publicAdmin"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "images-pusher" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "container-registry.images.pusher"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s-logging-writer" {
  folder_id = "b1gr6f3vahpkkk2de11c"
  role      = "logging.writer"
  member    = "serviceAccount:${yandex_iam_service_account.k8s-sa.id}"
}